module Config
  class Required; end

  def initialize(**config)
    @config = self.class.defaults.each_with_object({}) do |(name, default), memo|
      memo[name] = ENV.fetch(name.to_s.upcase, default)
    end

    @config.merge!(config)
    missing_required = @config.select { |_, value| value.is_a?(Required) }.map(&:first)
    raise "missing required config values; #{missing_required}" unless missing_required.empty?
  end

  def [](name)
    @config.fetch(name.to_sym)
  end

  def to_h
    @config
  end

  module ClassMethods
    def config(config)
      default = Required.new

      case config
      when String, Symbol
        name = config
      when Hash
        name, default_value = config.first
        default = default_value.respond_to?(:call) ? default_value.call : default_value
      else
        raise 'invalid arg to config. must be String, Symbol, or Hash'
      end

      name = name.to_sym
      defaults[name] = default

      define_method(name) { @config[name] }
    end

    def defaults
      @defaults ||= {}
    end
  end

  def self.included(base)
    base.extend(ClassMethods)
  end
end
