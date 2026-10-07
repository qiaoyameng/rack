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

      # When the error is raised by parse_nested_query_with_provenance,
      # these carry the sources of the conflicting values: the sources of
      # the leaf value(s) already present, and the source of the incoming
      # pair. Both are nil when the error is raised by any other entry
      # point. Sources only contain the pair index and character range,
      # never the parameter values themselves.
      attr_accessor :existing_sources, :incoming_source
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

    # The source of a single decoded query pair: its index among the
    # decoded key/value pairs (empty pairs are not counted) and its
    # character range in the original query string.
    PairSource = Struct.new(:pair_index, :range)

    # The source of a leaf value in the parsed params: the path of the leaf
    # from the root of the params (hash keys and array indices), plus the
    # index and character range of the query pair the value came from.
    LeafSource = Struct.new(:path, :pair_index, :range)

    # A leaf value that was overwritten by a later query pair during
    # parsing. +replaced_by+ is the PairSource of the overwriting pair.
    Overwrite = Struct.new(:path, :pair_index, :range, :replaced_by)

    # The result of parse_nested_query_with_provenance: +params+ is the
    # same hash parse_nested_query would return, +leaves+ holds a
    # LeafSource for every final leaf value, and +overwrites+ holds an
    # Overwrite for every value that was overwritten during parsing.
    Provenance = Struct.new(:params, :leaves, :overwrites)

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

    # parse_nested_query_with_provenance expands a query string exactly
    # like parse_nested_query, and additionally tracks where every value
    # came from. It returns a Provenance whose +params+ is identical to
    # the result of parse_nested_query for the same input, whose +leaves+
    # maps every final leaf value to the index and character range of the
    # original query pair it came from, and whose +overwrites+ lists the
    # sources of values that were overwritten by later pairs (for example
    # when the same decoded name appears more than once).
    #
    # If a ParameterTypeError is raised, its existing_sources and
    # incoming_source attributes carry the sources of both sides of the
    # conflict. Parameter values are never included in the error.
    def parse_nested_query_with_provenance(qs, separator = nil)
      params = make_params
      provenance = {}
      overwrites = []

      each_query_pair_with_offsets(qs, separator) do |k, v, pair_index, range|
        _normalize_params_with_trace(provenance, params, k, v, 0, [], PairSource.new(pair_index, range), overwrites)
      end

      leaves = []
      collect_leaf_sources(provenance, [], leaves)
      Provenance.new(params.to_h, leaves, overwrites)
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

    # Traced variant of _normalize_params, used only by
    # parse_nested_query_with_provenance so that parse_nested_query itself
    # bears no tracking overhead. It applies the exact same normalization
    # and merging rules, while mirroring the params structure into
    # +provenance+, where every leaf is the PairSource of the query pair
    # the corresponding value came from. +path+ is the path of +params+
    # from the root. Returns the [params, provenance] pair for the node,
    # mirroring the return values of _normalize_params.
    private def _normalize_params_with_trace(provenance, params, name, v, depth, path, source, overwrites)
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

      return [nil, nil] if k.empty?

      if after == ''
        if k == '[]' && depth != 0
          return [[v], [source]]
        else
          record_overwrite(overwrites, provenance, k, path, source) if params.key?(k)
          params[k] = v
          provenance[k] = source
        end
      elsif after == "["
        record_overwrite(overwrites, provenance, name, path, source) if params.key?(name)
        params[name] = v
        provenance[name] = source
      elsif after == "[]"
        params[k] ||= []
        provenance[k] ||= []
        raise_traced_type_error('Array', params[k], k, provenance[k], path, source) unless params[k].is_a?(Array)
        params[k] << v
        provenance[k] << source
      elsif after.start_with?('[]')
        # Recognize x[][y] (hash inside array) parameters
        unless after[2] == '[' && after.end_with?(']') && (child_key = after[3, after.length-4]) && !child_key.empty? && !child_key.index('[') && !child_key.index(']')
          # Handle other nested array parameters
          child_key = after[2, after.length]
        end
        params[k] ||= []
        provenance[k] ||= []
        raise_traced_type_error('Array', params[k], k, provenance[k], path, source) unless params[k].is_a?(Array)
        if params_hash_type?(params[k].last) && !params_hash_has_key?(params[k].last, child_key)
          _normalize_params_with_trace(provenance[k].last, params[k].last, child_key, v, depth + 1, path + [k, params[k].length - 1], source, overwrites)
        else
          child_params = make_params
          child_provenance = {}
          new_params, new_provenance = _normalize_params_with_trace(child_provenance, child_params, child_key, v, depth + 1, path + [k, params[k].length], source, overwrites)
          params[k] << new_params
          provenance[k] << new_provenance
        end
      else
        params[k] ||= make_params
        provenance[k] ||= {}
        raise_traced_type_error('Hash', params[k], k, provenance[k], path, source) unless params_hash_type?(params[k])
        params[k], provenance[k] = _normalize_params_with_trace(provenance[k], params[k], after, v, depth + 1, path + [k], source, overwrites)
      end

      [params, provenance]
    rescue Encoding::CompatibilityError
      raise IncompatibleEncodingError
    end

    # Records the sources of all leaf values stored at provenance[key]
    # (the values about to be discarded) as overwritten by +source+.
    private def record_overwrite(overwrites, provenance, key, path, source)
      leaves = []
      collect_leaf_sources(provenance[key], path + [key], leaves)
      leaves.each do |leaf|
        overwrites << Overwrite.new(leaf.path, leaf.pair_index, leaf.range, source)
      end
    end

    # Raises a ParameterTypeError for a conflicting parameter type, with
    # the sources of both the existing value(s) and the incoming pair
    # attached. The message is the same as the one _normalize_params
    # produces and never includes parameter values.
    private def raise_traced_type_error(expected, value, key, provenance, path, source)
      error = ParameterTypeError.new("expected #{expected} (got #{value.class.name}) for param `#{key}'")
      error.existing_sources = []
      collect_leaf_sources(provenance, path + [key], error.existing_sources)
      error.incoming_source = source
      raise error
    end

    # Collects a LeafSource for every PairSource leaf in the provenance
    # structure, prefixing each with +path+.
    private def collect_leaf_sources(node, path, leaves)
      if node.is_a?(PairSource)
        leaves << LeafSource.new(path, node.pair_index, node.range)
      elsif node.is_a?(Hash)
        node.each do |key, child|
          collect_leaf_sources(child, path + [key], leaves)
        end
      elsif node.is_a?(Array)
        node.each_with_index do |child, index|
          collect_leaf_sources(child, path + [index], leaves)
        end
      end
    end

    # Same splitting, decoding and limit handling as each_query_pair, but
    # also yields the index of each pair among the decoded pairs and its
    # character range in the original query string.
    private def each_query_pair_with_offsets(qs, separator)
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

      pair_index = 0
      offset = 0
      pairs.each do |p|
        start = offset
        offset += p.length
        if match = sep.match(qs, offset)
          offset = match.end(0)
        end
        next if p.empty?
        k, v = p.split('=', 2).map! { |s| unescape(s) }
        yield k, v, pair_index, start...start + p.length
        pair_index += 1
      end
    rescue ArgumentError => e
      raise InvalidParameterError, e.message, e.backtrace
    end

    def each_query_pair(qs, separator, unescaper = nil)
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

    def unescape(string, encoding = Encoding::UTF_8)
      URI.decode_www_form_component(string, encoding)
    end

    class Params < Hash
      alias_method :to_params_hash, :to_h
    end
  end
end
