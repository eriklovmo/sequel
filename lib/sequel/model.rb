require 'rubygems'
require 'metaid'

module Sequel
  class Model
    @@db = nil
    
    def self.db
      @db ||= ((superclass != Object) && (superclass.db)) || nil
    end
    def self.db=(db); @db = db; end
    
    def self.table_name
      @table_name ||= ((superclass != Model) && (superclass.table_name)) || nil
    end
    def self.set_table_name(t); @table_name = t; end

    def self.dataset
      return @dataset if @dataset
      if !table_name
        raise RuntimeError, "Table name not specified for class #{self}."
      elsif !db
        raise RuntimeError, "No database connected."
      end
      @dataset = db[table_name]
      @dataset.model_class = self
      @dataset
    end

    def self.set_dataset(ds)
      @db = ds.db
      @dataset = ds
      @dataset.model_class = self
    end
    
    def self.cache_by(column, expiration)
      @cache_column = column
      
      prefix = "#{name}.#{column}."
      define_method(:cache_key) do
        prefix + @values[column].to_s
      end
      
      define_method("find_by_#{column}".to_sym) do |arg|
        key = cache_key
        rec = CACHE[key]
        if !rec
          rec = find(column => arg)
          CACHE.set(key, rec, expiration)
        end
        rec
      end
      
      alias_method :destroy, :destroy_and_invalidate_cache
      alias_method :set, :set_and_update_cache
    end
    
    def self.cache_column
      @cache_column
    end
    
    def self.primary_key; @primary_key ||= :id; end
    def self.set_primary_key(k); @primary_key = k; end
    
    def self.set_schema(name = nil, &block)
      name ? set_table_name(name) : name = table_name
      @schema = Schema::Generator.new(name, &block)
      if @schema.primary_key_name
        set_primary_key @schema.primary_key_name
      end
    end
    def self.schema
      @schema || ((superclass != Model) && (superclass.schema))
    end
    
    def self.table_exists?
      db.table_exists?(table_name)
    end
    
    def self.create_table
      db.execute schema.create_sql
    end
    
    def self.drop_table
      db.execute schema.drop_sql
    end
    
    def self.recreate_table
      drop_table if table_exists?
      create_table
    end
    
    def self.subset(name, *args, &block)
      meta_def(name) {filter(*args, &block)}
    end
    
    ONE_TO_ONE_PROC = "proc {i = @values[:%s]; %s[i] if i}".freeze
    ID_POSTFIX = "_id".freeze
    FROM_DATASET = "db[%s]".freeze
    
    def self.one_to_one(name, opts)
      klass = opts[:class] ? opts[:class] : (FROM_DATASET % name.inspect)
      key = opts[:key] || (name.to_s + ID_POSTFIX)
      define_method name, &eval(ONE_TO_ONE_PROC % [key, klass])
    end
  
    ONE_TO_MANY_PROC = "proc {%s.filter(:%s => @pkey)}".freeze
    ONE_TO_MANY_ORDER_PROC = "proc {%s.filter(:%s => @pkey).order(%s)}".freeze
    def self.one_to_many(name, opts)
      klass = opts[:class] ? opts[:class] :
        (FROM_DATASET % (opts[:table] || name.inspect))
      key = opts[:on]
      order = opts[:order]
      define_method name, &eval(
        (order ? ONE_TO_MANY_ORDER_PROC : ONE_TO_MANY_PROC) %
        [klass, key, order.inspect]
      )
    end
    
    def self.get_hooks(key)
      @hooks ||= {}
      @hooks[key] ||= []
    end
    
    def self.has_hooks?(key)
      !get_hooks(key).empty?
    end
    
    def run_hooks(key)
      self.class.get_hooks(key).each {|h| instance_eval(&h)}
    end
    
    def self.before_save(&block)
      get_hooks(:before_save).unshift(block)
    end
    
    def self.before_create(&block)
      get_hooks(:before_create).unshift(block)
    end
    
    def self.before_destroy(&block)
      get_hooks(:before_destroy).unshift(block)
    end
    
    def self.after_save(&block)
      get_hooks(:after_save) << block
    end
    
    def self.after_create(&block)
      get_hooks(:after_create) << block
    end
    
    def self.after_destroy(&block)
      get_hooks(:after_destroy).unshift(block)
    end
    
    def self.find(cond)
      dataset[cond.is_a?(Hash) ? cond : {primary_key => cond}]
    end
    
    def self.find_or_create(cond)
      find(cond) || create(cond)
    end

    class << self; alias_method :[], :find; end
    
    ############################################################################
    
    attr_reader :values, :pkey
    
    def model
      self.class
    end
    
    def primary_key
      self.class.primary_key
    end
    
    def initialize(values)
      @values = values
      @pkey = values[self.class.primary_key]
    end
    
    def exists?
      model.filter(primary_key => @pkey).count == 1
    end
    
    def refresh
      @values = self.class.dataset.naked[primary_key => @pkey] ||
        (raise RuntimeError, "Record not found")
      self
    end
    
    def self.each(&block); dataset.each(&block); end
    def self.all; dataset.all; end
    def self.filter(*arg, &block); dataset.filter(*arg, &block); end
    def self.exclude(*arg, &block); dataset.exclude(*arg, &block); end
    def self.order(*arg); dataset.order(*arg); end
    def self.first(*arg); dataset.first(*arg); end
    def self.count; dataset.count; end
    def self.map(*arg, &block); dataset.map(*arg, &block); end
    def self.hash_column(column); dataset.hash_column(primary_key, column); end
    def self.join(*args); dataset.join(*args); end
    def self.lock(mode, &block); dataset.lock(mode, &block); end
    def self.destroy_all
      has_hooks?(:before_destroy) ? dataset.destroy : dataset.delete
    end
    def self.delete_all; dataset.delete; end
    
    def self.create(values = nil)
      db.transaction do
        obj = new(values || {})
        obj.save
        obj
      end
    end
    
    def destroy
      db.transaction do
        run_hooks(:before_destroy)
        delete
      end
    end
    
    def delete
      model.dataset.filter(primary_key => @pkey).delete
    end
    
    FIND_BY_REGEXP = /^find_by_(.*)/.freeze
    FILTER_BY_REGEXP = /^filter_by_(.*)/.freeze
    ALL_BY_REGEXP = /^all_by_(.*)/.freeze
    
    def self.method_missing(m, *args)
      Thread.exclusive do
        method_name = m.to_s
        if method_name =~ FIND_BY_REGEXP
          c = $1
          meta_def(method_name) {|arg| find(c => arg)}
        elsif method_name =~ FILTER_BY_REGEXP
          c = $1
          meta_def(method_name) {|arg| filter(c => arg)}
        elsif method_name =~ ALL_BY_REGEXP
          c = $1
          meta_def(method_name) {|arg| filter(c => arg).all}
        end
      end
      respond_to?(m) ? send(m, *args) : super(m, *args)
    end
    
    def db; self.class.db; end
    
    def [](field); @values[field]; end
    
    def []=(field, value); @values[field] = value; end
    
    WRITE_ATTR_REGEXP = /(.*)=$/.freeze

    def method_missing(m, value = nil)
      if m.to_s =~ WRITE_ATTR_REGEXP
        self[$1.to_sym] = value
      else
        self[m]
      end
    end
    
    def id; @values[:id]; end
    
    def save
      run_hooks(:before_save)
      if @pkey
        run_hooks(:before_update)
        model.dataset.filter(primary_key => @pkey).update(@values)
        run_hooks(:after_update)
      else
        run_hooks(:before_create)
        @pkey = model.dataset.insert(@values)
        refresh
        run_hooks(:after_create)
      end
      run_hooks(:after_save)
    end
    
    def ==(obj)
      (obj.class == model) && (obj.values == @values)
    end
    
    def set(values)
      model.dataset.filter(primary_key => @pkey).update(values)
      @values.merge!(values)
    end
  end
  
  def self.Model(table)
    Class.new(Sequel::Model) do
      meta_def(:inherited) do |c|
        if table.is_a?(Dataset)
          c.set_dataset(table)
        else
          c.set_table_name(table)
        end
      end
    end
  end
end
