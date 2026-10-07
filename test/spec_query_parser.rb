# frozen_string_literal: true

require_relative 'helper'

separate_testing do
  require_relative '../lib/rack/query_parser'
end

describe Rack::QueryParser do
  it "can normalize values with missing values" do
    query_parser = Rack::QueryParser.make_default(8)
    query_parser.parse_nested_query("a=a").must_equal({"a" => "a"})
    query_parser.parse_nested_query("a=").must_equal({"a" => ""})
    query_parser.parse_nested_query("a").must_equal({"a" => nil})
    query_parser.parse_query_pairs("a=a").must_equal([["a", "a"]])
    query_parser.parse_query_pairs("a=").must_equal([["a", ""]])
    query_parser.parse_query_pairs("a").must_equal([["a", nil]])
  end

  it "accepts bytesize_limit to specify maximum size of query string to parse" do
    query_parser = Rack::QueryParser.make_default(32, bytesize_limit: 3)
    query_parser.parse_query("a=a").must_equal({"a" => "a"})
    query_parser.parse_nested_query("a=a").must_equal({"a" => "a"})
    query_parser.parse_nested_query("a=a", '&').must_equal({"a" => "a"})
    query_parser.parse_query_pairs("a=a").must_equal([["a", "a"]])
    proc { query_parser.parse_query("a=aa") }.must_raise Rack::QueryParser::QueryLimitError
    proc { query_parser.parse_nested_query("a=aa") }.must_raise Rack::QueryParser::QueryLimitError
    proc { query_parser.parse_nested_query("a=aa", '&') }.must_raise Rack::QueryParser::QueryLimitError
    proc { query_parser.parse_query_pairs("a=aa") }.must_raise Rack::QueryParser::QueryLimitError
  end

  it "does not enforce a bytesize limit when bytesize_limit is nil" do
    query_parser = Rack::QueryParser.make_default(32, bytesize_limit: nil)
    query_parser.parse_query("a=aa").must_equal({"a" => "aa"})
    query_parser.parse_nested_query("a=aa").must_equal({"a" => "aa"})
    query_parser.parse_nested_query("a=aa", '&').must_equal({"a" => "aa"})
    query_parser.parse_query_pairs("a=aa").must_equal([["a", "aa"]])
  end

  it "accepts params_limit to specify maximum number of query parameters to parse" do
    query_parser = Rack::QueryParser.make_default(32, params_limit: 2)
    query_parser.parse_query("a=a&b=b").must_equal({"a" => "a", "b" => "b"})
    query_parser.parse_nested_query("a=a&b=b").must_equal({"a" => "a", "b" => "b"})
    query_parser.parse_nested_query("a=a&b=b", '&').must_equal({"a" => "a", "b" => "b"})
    query_parser.parse_query_pairs("a=a&b=b").must_equal([["a", "a"], ["b", "b"]])
    query_parser.parse_query_pairs("a=1&a=2").must_equal([["a", "1"], ["a", "2"]])
    proc { query_parser.parse_query("a=a&b=b&c=c") }.must_raise Rack::QueryParser::QueryLimitError
    proc { query_parser.parse_nested_query("a=a&b=b&c=c", '&') }.must_raise Rack::QueryParser::QueryLimitError
    proc { query_parser.parse_query("b[]=a&b[]=b&b[]=c") }.must_raise Rack::QueryParser::QueryLimitError
    proc { query_parser.parse_query_pairs("a=a&b=b&c=c") }.must_raise Rack::QueryParser::QueryLimitError
  end

  it "does not enforce a params limit when params_limit is nil" do
    query_parser = Rack::QueryParser.make_default(32, params_limit: nil)
    query_parser.parse_query("a=a&b=b&c=c").must_equal({"a" => "a", "b" => "b", "c" => "c"})
    query_parser.parse_nested_query("a=a&b=b&c=c").must_equal({"a" => "a", "b" => "b", "c" => "c"})
  end

  it "raises when normalizing params with incompatible encoding such as UTF-16LE" do
    query_parser = Rack::QueryParser.make_default(8)
    name = "utf-16le".dup.force_encoding("UTF-16LE")
    value = "Alice?".dup.force_encoding("UTF-16LE")
    lambda {
      query_parser.normalize_params({}, name, value)
    }.must_raise(::Rack::QueryParser::IncompatibleEncodingError)
  end
end

describe "Rack::QueryParser provenance tracking" do
  let(:query_parser) { Rack::QueryParser.make_default(32) }

  it "returns the same params as parse_nested_query for the same input" do
    inputs = [
      nil, "", "&", "a", "a=", "=1", "a=1", "a=1&b=2", "a=1&a=2",
      "a&a=1", "a&a[]=1", "a&a[b]=1", "a=&a=", "a=1&&b=2",
      "a[b]=1&a[b]=2", "a[b]=1&a[b]=2&a[b]=3",
      "a[]=1&a[]=2", "a[][]=1", "a[][x]=1&a[][y]=2", "a[][x]=1&a[][x]=2",
      "a[][x]=1&a[][y]=2&a[][x]=3", "x[y][z]=1", "x[y][]=1&x[y][]=2",
      "a[b=1", "a[=1", "a[]b]=1", "a%5Bb%5D=1&a[b]=2", "x[][y][][z]=1",
    ]
    inputs.each do |qs|
      params, = query_parser.parse_nested_query_with_provenance(qs)
      params.must_equal query_parser.parse_nested_query(qs), "params differ for #{qs.inspect}"
    end

    ["a=1&a[]=2", "a=1&a[b]=2"].each do |qs|
      proc { query_parser.parse_nested_query_with_provenance(qs) }.
        must_raise Rack::QueryParser::ParameterTypeError
    end
  end

  it "records the source of structural values overwritten by later pairs" do
    qs = "a[]=1&a=2"
    params, provenance = query_parser.parse_nested_query_with_provenance(qs)
    params.must_equal({ "a" => "2" })
    leaf = provenance["a"]
    qs[leaf.range].must_equal "a=2"
    leaf.overwritten.size.must_equal 1
    qs[leaf.overwritten[0][0].range].must_equal "a[]=1"

    qs = "x[y]=1&x=2"
    params, provenance = query_parser.parse_nested_query_with_provenance(qs)
    params.must_equal({ "x" => "2" })
    leaf = provenance["x"]
    qs[leaf.range].must_equal "x=2"
    qs[leaf.overwritten[0]["y"].range].must_equal "x[y]=1"
  end

  it "returns empty params and provenance for nil or empty query strings" do
    params, provenance = query_parser.parse_nested_query_with_provenance(nil)
    params.must_equal({})
    provenance.must_equal({})
    params, provenance = query_parser.parse_nested_query_with_provenance("")
    params.must_equal({})
    provenance.must_equal({})
  end

  it "tracks the source of each final leaf and of overwritten duplicate keys" do
    qs = "a[b]=1&a[b]=2"
    params, provenance = query_parser.parse_nested_query_with_provenance(qs)
    params.must_equal({ "a" => { "b" => "2" } })

    leaf = provenance["a"]["b"]
    leaf.param_index.must_equal 1
    qs[leaf.range].must_equal "a[b]=2"
    leaf.overwritten.size.must_equal 1
    leaf.overwritten[0].param_index.must_equal 0
    qs[leaf.overwritten[0].range].must_equal "a[b]=1"
  end

  it "chains sources for values overwritten multiple times" do
    qs = "a=1&a=2&a=3"
    params, provenance = query_parser.parse_nested_query_with_provenance(qs)
    params.must_equal({ "a" => "3" })

    leaf = provenance["a"]
    leaf.param_index.must_equal 2
    qs[leaf.range].must_equal "a=3"
    leaf.overwritten.map(&:param_index).must_equal [0, 1]
    qs[leaf.overwritten[0].range].must_equal "a=1"
    qs[leaf.overwritten[1].range].must_equal "a=2"
  end

  it "tracks sources through arrays and hash-in-array merging" do
    qs = "a[]=1&a[]=2"
    params, provenance = query_parser.parse_nested_query_with_provenance(qs)
    params.must_equal({ "a" => ["1", "2"] })
    provenance["a"].map(&:param_index).must_equal [0, 1]
    qs[provenance["a"][0].range].must_equal "a[]=1"
    qs[provenance["a"][1].range].must_equal "a[]=2"

    qs = "a[][x]=1&a[][y]=2&a[][x]=3"
    params, provenance = query_parser.parse_nested_query_with_provenance(qs)
    params.must_equal({ "a" => [{ "x" => "1", "y" => "2" }, { "x" => "3" }] })
    provenance["a"].size.must_equal 2
    qs[provenance["a"][0]["x"].range].must_equal "a[][x]=1"
    qs[provenance["a"][0]["y"].range].must_equal "a[][y]=2"
    qs[provenance["a"][1]["x"].range].must_equal "a[][x]=3"
    provenance["a"][1]["x"].param_index.must_equal 2
  end

  it "tracks sources for bare keys, empty values and encoded names" do
    qs = "a&a=&a=1"
    params, provenance = query_parser.parse_nested_query_with_provenance(qs)
    params.must_equal({ "a" => "1" })
    leaf = provenance["a"]
    qs[leaf.range].must_equal "a=1"
    leaf.overwritten.map { |source| qs[source.range] }.must_equal ["a", "a="]

    qs = "a%5Bb%5D=1&a[b]=2"
    params, provenance = query_parser.parse_nested_query_with_provenance(qs)
    params.must_equal({ "a" => { "b" => "2" } })
    leaf = provenance["a"]["b"]
    qs[leaf.range].must_equal "a[b]=2"
    qs[leaf.overwritten[0].range].must_equal "a%5Bb%5D=1"
  end

  it "raises ParameterTypeError carrying both sources without echoing values" do
    qs = "secret=topsecret&secret[]=1"
    error = proc { query_parser.parse_nested_query_with_provenance(qs) }.
      must_raise Rack::QueryParser::ParameterTypeError
    error.message.must_equal "expected Array (got String) for param `secret'"
    error.message.wont_include "topsecret"
    qs[error.existing_source.range].must_equal "secret=topsecret"
    error.existing_source.param_index.must_equal 0
    qs[error.incoming_source.range].must_equal "secret[]=1"
    error.incoming_source.param_index.must_equal 1

    error = proc { query_parser.parse_nested_query("a=1&a[b]=2") }.
      must_raise Rack::QueryParser::ParameterTypeError
    error.existing_source.must_be_nil
    error.incoming_source.must_be_nil
  end

  it "enforces the param depth limit like the regular parser" do
    shallow_parser = Rack::QueryParser.make_default(2)
    proc { shallow_parser.parse_nested_query_with_provenance("a[b][c]=1") }.
      must_raise Rack::QueryParser::ParamsTooDeepError
    proc { shallow_parser.parse_nested_query("a[b][c]=1") }.
      must_raise Rack::QueryParser::ParamsTooDeepError
  end

  it "enforces bytesize and params limits like the regular parser" do
    limited_parser = Rack::QueryParser.make_default(32, bytesize_limit: 3)
    proc { limited_parser.parse_nested_query_with_provenance("a=aa") }.
      must_raise Rack::QueryParser::QueryLimitError

    limited_parser = Rack::QueryParser.make_default(32, params_limit: 2)
    proc { limited_parser.parse_nested_query_with_provenance("a=a&b=b&c=c") }.
      must_raise Rack::QueryParser::QueryLimitError
  end

  it "tracks sources with custom separators" do
    qs = "a=1; a=2"
    params, provenance = query_parser.parse_nested_query_with_provenance(qs, ";")
    params.must_equal({ "a" => "2" })
    leaf = provenance["a"]
    qs[leaf.range].must_equal "a=2"
    qs[leaf.overwritten[0].range].must_equal "a=1"
  end
end
