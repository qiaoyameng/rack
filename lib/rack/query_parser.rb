# frozen_string_literal: true

require_relative 'bad_request'
require 'uri'

module Rack
  class QueryParser
    DEFAULT_SEP = /& */n
    COMMON_SEP = { ";" => /; */n, ";," => /[;,] */n, "&" => /& */n }

    # ParameterTypeError is the error that is raised when incoming structural
    # parameters (parsed by parse_nested_query) contain conflicting types.
    class ParameterTypeError < TypeError
      include BadRequest

      # When raised by parse_nested_query_with_provenance, these hold the
      # ParameterSource of the previously parsed parameter and of the
      # incoming parameter that conflicted with each other. Both are nil for
      # errors raised by the untracked parsing entry points. Note that only
      # source locations are exposed here, never parameter values.
      attr_reader :existing_source, :incoming_source

      def initialize(message = nil, existing_source: nil, incoming_source: nil)
        super(message)
        @existing_source = existing_source
        @incoming_source = incoming_source
      end
    end

    # ParameterSource describes where a single query parameter came from in
    # the original query string. It is produced by
    # parse_nested_query_with_provenance and records the 0-based index of the
    # key=value pair (counting only non-empty pairs) and the character range
    # of that pair in the original query string, so the raw pair can be
    # recovered with query_string[source.range].
    class ParameterSource
      attr_reader :param_index, :range

      # Provenance nodes that were overwritten by the assignment this source
      # belongs to, oldest first. Entries are either ParameterSource
      # instances (overwritten leaf values) or Hash/Array provenance nodes
      # (overwritten structural values).
      attr_reader :overwritten

      def initialize(param_index, range, overwritten = [])
        @param_index = param_index
        @range = range
        @overwritten = overwritten
      end

      def ==(other)
        other.is_a?(ParameterSource) &&
          param_index == other.param_index &&
          range == other.range &&
          overwritten == other.overwritten
      end
      alias_method :eql?, :==

      def inspect
        "#<#{self.class.name} param_index=#{param_index} range=#{range}>"
      end
    end

    # InvalidParameterError is the error that is raised when incoming structural
    # parameters (parsed by parse_nested_query) contain invalid format or byte
    # sequence.
    class InvalidParameterError < ArgumentError
      include BadRequest
    end

    # QueryLimitError is for errors raised when the query provided exceeds one
    # of the query parser limits.
    class QueryLimitError < RangeError
      include BadRequest
    end

    class IncompatibleEncodingError < EncodingError
      include BadRequest
    end

    # ParamsTooDeepError is the old name for the error that is raised when params
    # are recursively nested over the specified limit. Make it the same as
    # as QueryLimitError, so that code that rescues ParamsTooDeepError error
    # to handle bad query strings also now handles other limits.
    ParamsTooDeepError = QueryLimitError

    def self.make_default(param_depth_limit, **options)
      new(Params, param_depth_limit, **options)
    end

    attr_reader :param_depth_limit

    env_int = lambda do |key, val|
      if str_val = ENV[key]
        begin
          val = Integer(str_val, 10)
        rescue ArgumentError
          raise ArgumentError, "non-integer value provided for environment variable #{key}"
        end
      end

      val if val >= 0
    end

    BYTESIZE_LIMIT = env_int.call("RACK_QUERY_PARSER_BYTESIZE_LIMIT", 4194304)
    private_constant :BYTESIZE_LIMIT

    PARAMS_LIMIT = env_int.call("RACK_QUERY_PARSER_PARAMS_LIMIT", 4096)
    private_constant :PARAMS_LIMIT

    attr_reader :bytesize_limit

    def initialize(params_class, param_depth_limit, bytesize_limit: BYTESIZE_LIMIT, params_limit: PARAMS_LIMIT)
      @params_class = params_class
      @param_depth_limit = param_depth_limit
      @bytesize_limit = bytesize_limit
      @params_limit = params_limit
    end

    # Stolen from Mongrel, with some small modifications:
    # Parses a query string by breaking it up at the '&'.  You can also use this
    # to parse cookies by changing the characters used in the second parameter
    # (which defaults to '&').
    def parse_query(qs, separator = nil, &unescaper)
      params = make_params

      each_query_pair(qs, separator, unescaper) do |k, v|
        if cur = params[k]
          if cur.class == Array
            params[k] << v
          else
            params[k] = [cur, v]
          end
        else
          params[k] = v
        end
      end

      return params.to_h
    end

    # Parses a query string by breaking it up at the '&', returning all key-value
    # pairs as an array of [key, value] arrays. Unlike parse_query, this preserves
    # all duplicate keys rather than collapsing them.
    def parse_query_pairs(qs, separator = nil)
      pairs = []

      each_query_pair(qs, separator) do |k, v|
        pairs << [k, v]
      end

      pairs
    end

    # parse_nested_query expands a query string into structural types. Supported
    # types are Arrays, Hashes and basic value types. It is possible to supply
    # query strings with parameters of conflicting types, in this case a
    # ParameterTypeError is raised. Users are encouraged to return a 400 in this
    # case.
    def parse_nested_query(qs, separator = nil)
      params = make_params

      each_query_pair(qs, separator) do |k, v|
        _normalize_params(params, k, v, 0)
      end

      return params.to_h
    end

    # parse_nested_query_with_provenance behaves exactly like
    # parse_nested_query, but additionally tracks where every value in the
    # result came from in the original query string. It returns a two element
    # array of [params, provenance], where params is identical to the result
    # of parse_nested_query for the same input, and provenance is a structure
    # mirroring params: hashes and arrays in params have corresponding Hash and
    # Array nodes in provenance, and each scalar leaf has a ParameterSource
    # recording the index and character range of the original key=value pair.
    # When a later pair overwrites an earlier value, the sources of the
    # overwritten values are available via ParameterSource#overwritten.
    #
    # Type conflicts raise ParameterTypeError just like parse_nested_query,
    # with the sources of both conflicting parameters available via
    # ParameterTypeError#existing_source and #incoming_source.
    def parse_nested_query_with_provenance(qs, separator = nil)
      params = make_params
      provenance = {}

      each_query_pair_with_source(qs, separator) do |k, v, source|
        _normalize_params_tracked(params, provenance, k, v, 0, source)
      end

      return params.to_h, provenance
    end

    # normalize_params recursively expands parameters into structural types. If
    # the structural types represented by two different parameter names are in
    # conflict, a ParameterTypeError is raised.  The depth argument is deprecated
    # and should no longer be used, it is kept for backwards compatibility with
    # earlier versions of rack.
    def normalize_params(params, name, v, _depth=nil)
      _normalize_params(params, name, v, 0)
    end

    private def _normalize_params(params, name, v, depth)
      raise ParamsTooDeepError if depth >= param_depth_limit

      if !name
        # nil name, treat same as empty string (required by tests)
        k = after = ''
      elsif depth == 0
        # Start of parsing, don't treat [] or [ at start of string specially
        if start = name.index('[', 1)
          # Start of parameter nesting, use part before brackets as key
          k = name[0, start]
          after = name[start, name.length]
        else
          # Plain parameter with no nesting
          k = name
          after = ''
        end
      elsif name.start_with?('[]')
        # Array nesting
        k = '[]'
        after = name[2, name.length]
      elsif name.start_with?('[') && (start = name.index(']', 1))
        # Hash nesting, use the part inside brackets as the key
        k = name[1, start-1]
        after = name[start+1, name.length]
      else
        # Probably malformed input, nested but not starting with [
        # treat full name as key for backwards compatibility.
        k = name
        after = ''
      end

      return if k.empty?

      if after == ''
        if k == '[]' && depth != 0
          return [v]
        else
          params[k] = v
        end
      elsif after == "["
        params[name] = v
      elsif after == "[]"
        params[k] ||= []
        raise ParameterTypeError, "expected Array (got #{params[k].class.name}) for param `#{k}'" unless params[k].is_a?(Array)
        params[k] << v
      elsif after.start_with?('[]')
        # Recognize x[][y] (hash inside array) parameters
        unless after[2] == '[' && after.end_with?(']') && (child_key = after[3, after.length-4]) && !child_key.empty? && !child_key.index('[') && !child_key.index(']')
          # Handle other nested array parameters
          child_key = after[2, after.length]
        end
        params[k] ||= []
        raise ParameterTypeError, "expected Array (got #{params[k].class.name}) for param `#{k}'" unless params[k].is_a?(Array)
        if params_hash_type?(params[k].last) && !params_hash_has_key?(params[k].last, child_key)
          _normalize_params(params[k].last, child_key, v, depth + 1)
        else
          params[k] << _normalize_params(make_params, child_key, v, depth + 1)
        end
      else
        params[k] ||= make_params
        raise ParameterTypeError, "expected Hash (got #{params[k].class.name}) for param `#{k}'" unless params_hash_type?(params[k])
        params[k] = _normalize_params(params[k], after, v, depth + 1)
      end

      params
    rescue Encoding::CompatibilityError
      raise IncompatibleEncodingError
    end

    # Tracked variant of _normalize_params, used only by
    # parse_nested_query_with_provenance. It mirrors _normalize_params exactly
    # (same handling of duplicate names, empty values, bare keys, type
    # conflicts and depth limits), while recording a ParameterSource for every
    # leaf it assigns. provenance mirrors the structure of params. Returns a
    # [value, provenance] pair wherever _normalize_params returns a value.
    private def _normalize_params_tracked(params, provenance, name, v, depth, source)
      raise ParamsTooDeepError if depth >= param_depth_limit

      if !name
        # nil name, treat same as empty string (required by tests)
        k = after = ''
      elsif depth == 0
        # Start of parsing, don't treat [] or [ at start of string specially
        if start = name.index('[', 1)
          # Start of parameter nesting, use part before brackets as key
          k = name[0, start]
          after = name[start, name.length]
        else
          # Plain parameter with no nesting
          k = name
          after = ''
        end
      elsif name.start_with?('[]')
        # Array nesting
        k = '[]'
        after = name[2, name.length]
      elsif name.start_with?('[') && (start = name.index(']', 1))
        # Hash nesting, use the part inside brackets as the key
        k = name[1, start-1]
        after = name[start+1, name.length]
      else
        # Probably malformed input, nested but not starting with [
        # treat full name as key for backwards compatibility.
        k = name
        after = ''
      end

      return if k.empty?

      if after == ''
        if k == '[]' && depth != 0
          return [v], [source]
        else
          provenance[k] = source_replacing(source, provenance[k])
          params[k] = v
        end
      elsif after == "["
        provenance[name] = source_replacing(source, provenance[name])
        params[name] = v
      elsif after == "[]"
        unless params[k]
          params[k] = []
          provenance[k] = []
        end
        raise tracked_type_error("expected Array (got #{params[k].class.name}) for param `#{k}'", provenance[k], source) unless params[k].is_a?(Array)
        params[k] << v
        provenance[k] << source
      elsif after.start_with?('[]')
        # Recognize x[][y] (hash inside array) parameters
        unless after[2] == '[' && after.end_with?(']') && (child_key = after[3, after.length-4]) && !child_key.empty? && !child_key.index('[') && !child_key.index(']')
          # Handle other nested array parameters
          child_key = after[2, after.length]
        end
        unless params[k]
          params[k] = []
          provenance[k] = []
        end
        raise tracked_type_error("expected Array (got #{params[k].class.name}) for param `#{k}'", provenance[k], source) unless params[k].is_a?(Array)
        if params_hash_type?(params[k].last) && !params_hash_has_key?(params[k].last, child_key)
          _normalize_params_tracked(params[k].last, provenance[k].last, child_key, v, depth + 1, source)
        else
          child_provenance = {}
          value, value_provenance = _normalize_params_tracked(make_params, child_provenance, child_key, v, depth + 1, source)
          params[k] << value
          provenance[k] << value_provenance
        end
      else
        unless params[k]
          params[k] = make_params
          provenance[k] = {}
        end
        raise tracked_type_error("expected Hash (got #{params[k].class.name}) for param `#{k}'", provenance[k], source) unless params_hash_type?(params[k])
        params[k], provenance[k] = _normalize_params_tracked(params[k], provenance[k], after, v, depth + 1, source)
      end

      [params, provenance]
    rescue Encoding::CompatibilityError
      raise IncompatibleEncodingError
    end

    # Builds the provenance node for a leaf assignment, recording the
    # previously assigned node (if any) as overwritten.
    private def source_replacing(source, previous)
      case previous
      when nil
        source
      when ParameterSource
        ParameterSource.new(source.param_index, source.range, previous.overwritten + [previous])
      else
        ParameterSource.new(source.param_index, source.range, [previous])
      end
    end

    private def tracked_type_error(message, existing_source, incoming_source)
      ParameterTypeError.new(message, existing_source: existing_source, incoming_source: incoming_source)
    end

    def make_params
      @params_class.new
    end

    def new_depth_limit(param_depth_limit)
      self.class.new @params_class, param_depth_limit
    end

    private

    def params_hash_type?(obj)
      obj.kind_of?(@params_class)
    end

    def params_hash_has_key?(hash, key)
      return false if /\[\]/.match?(key)

      key.split(/[\[\]]+/).inject(hash) do |h, part|
        next h if part == ''
        return false unless params_hash_type?(h) && h.key?(part)
        h[part]
      end

      true
    end

    def each_query_pair(qs, separator, unescaper = nil)
      return unless pairs = split_query_pairs(qs, separator)

      if unescaper
        pairs.each do |p|
          next if p.empty?
          k, v = p.split('=', 2).map!(&unescaper)
          yield k, v
        end
      else
        pairs.each do |p|
          next if p.empty?
          k, v = p.split('=', 2).map! { |s| unescape(s) }
          yield k, v
        end
      end
    rescue ArgumentError => e
      raise InvalidParameterError, e.message, e.backtrace
    end

    # Splits a query string into raw key=value pair strings, enforcing the
    # bytesize and params limits. Returns nil for nil or empty input.
    def split_query_pairs(qs, separator)
      return if !qs || qs.empty?

      if @bytesize_limit && qs.bytesize > @bytesize_limit
        raise QueryLimitError, "total query size exceeds limit (#{@bytesize_limit})"
      end

      sep = separator ? (COMMON_SEP[separator] || /[#{separator}] */n) : DEFAULT_SEP
      pairs = @params_limit ? qs.split(sep, @params_limit + 1) : qs.split(sep)

      if @params_limit && pairs.size > @params_limit
        param_count = pairs.size + pairs.last.count(separator || "&")
        raise QueryLimitError, "total number of query parameters (#{param_count}) exceeds limit (#{@params_limit})"
      end

      pairs
    end

    # Like each_query_pair, but also yields a ParameterSource locating each
    # pair in the original query string. Only used by the provenance tracking
    # entry point, so the untracked entry points do not pay for source
    # tracking.
    def each_query_pair_with_source(qs, separator)
      return unless pairs = split_query_pairs(qs, separator)

      index = 0
      offset = 0
      pairs.each do |p|
        next if p.empty?
        start = qs.index(p, offset)
        k, v = p.split('=', 2).map! { |s| unescape(s) }
        yield k, v, ParameterSource.new(index, start...(start + p.length))
        index += 1
        offset = start + p.length
      end
    rescue ArgumentError => e
      raise InvalidParameterError, e.message, e.backtrace
    end

    def unescape(string, encoding = Encoding::UTF_8)
      URI.decode_www_form_component(string, encoding)
    end

    class Params < Hash
      alias_method :to_params_hash, :to_h
    end
  end
end
