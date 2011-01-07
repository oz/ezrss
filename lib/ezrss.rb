#!/usr/bin/env ruby -rubygems

require 'simple-rss'
require 'typhoeus'
require 'pp'

module Ezrss

  # Search shows on Ezrss. This is actually a shortcut for
  # Ezrss::Search.new(...).result_set
  #
  # @param [String, Array] shows A show name, or list of show names
  # @param [Hash]          opts  Other optional parameters
  # @see Ezrss::Search
  def self.search shows, opts = {}
    Ezrss::Search.new(shows, opts).result_set
  end

  # @class Ezrss::Search
  # Search shows on EzRSS
  class Search

    attr_accessor :max_concurrency
    attr_reader   :result_set, :errors

    def initialize shows, opts = {}
      @max_concurrency = 20
      @shows           = shows.is_a?(Array) ? shows : [shows]
      @errors          = {}
      @show_data       = {}
      @ssl             = opts[:ssl]   || false
      @exact           = opts[:exact] || false
      @result_set      = ResultSet.new source: self
      @fed             = false
    end

    # Wether the query was sent
    def fed?
      @fed
    end

    # Get search results from ezrss.it
    #
    # @return [Ezrss::ResultSet]
    def fetch
      return @show_data unless @show_data
      hydra = Typhoeus::Hydra.new max_concurrency: @max_concurrency
      @shows.each { |show| hydra.queue fetch_rss_request(show) }
      hydra.run # Blocks
      @fed = true
      @result_set
    end
    alias :feed! :fetch

    protected

    # @param  [String] show Show name
    # @return [String] HTTP search URI
    def search_url show
      exact = @exact ? '&show_name_exact=true' : ''
      ( 'http%s://ezrss.it/search/index.php?show_name=%s' +
        '&date=&quality=&release_group=&mode=rss%s' ) % [ @ssl ? 's' : '',
                                                          show,
                                                          exact ]
    end

    # Build a queue-able Typhoeus request
    #
    # @param  [String] show Show name
    # @return [Typhoeus::Request] Search request
    def fetch_rss_request show
      req = Typhoeus::Request.new search_url(show)
      req.on_complete do |response|
        if response.code == 200
          @result_set << [ show, rss_items(response.body) ]
        else
          @errors[show] = response.body
        end
      end

      req
    end

    # @param [#to_s] RSS data
    # @return [Hash] SimpleRSS enriched RSS-items
    def rss_items data
      SimpleRSS.parse(data).items
    end
  end

  # Ezrss search results
  # @class Ezrss::Resultset
  class ResultSet
    include Enumerable

    attr_reader :results

    def initialize opts = {}
      @source  = opts[:source]
      @filters = []
      @results = {}
    end

    # Append data to the result set for a show.
    #
    # @param [Array] rss A two element array. The first element is a show name,
    #                    and the second element is an array of parsed RSS items
    #                    for this show.
    # @return [Ezrss::ResultSet]
    def << rss
      @results[rss[0]] ||= []
      @results[rss[0]].push *rss[1]
      self
    end

    # Add a filter to a ResultSet.  A filter can be applied to one particular
    # show name passed to Ezrss.search, or can be omitted entirely of the filter
    # is to apply to several shows.
    #
    #   # Filter only on the results of the 'foo' show
    #   Ezrss.search(['foo', 'bar']).where('foo', title: /08x/)
    #
    #   # Filter only on the results of any show
    #   Ezrss.search(['foo', 'bar']).where(title: /08x/)
    #
    # Filters can also be Proc objects, that accept exactly one parameter
    # which is one item of the RSS feed (@see the simple-rss gem).
    #
    #   # Filter on date : find releases published after november, 1st 2010.
    #   require 'date' # get #to_date
    #   Ezrss.search('foo').where { |show| show.pubDate.to_date > Date.parse('2010-11-01') }
    #
    # @return [Ezrss::ResultSet]
    def where *args, &block
      @_show_list_cache = nil
      show = args.first.is_a?(String) ? args.shift : Regexp.new(/.*/)
      @filters << [ show, block ] if block_given?
      args.each do |arg|
        if arg.is_a? String
          show = arg
        elsif arg.is_a? Hash
          arg.to_a.each { |*splat| @filters << expand_hash_filter(show, splat) }
        elsif arg.is_a? Proc
          @filters << [ show, arg ]
        end
      end

      self
    end
    alias :pick :where

    # Return the list of all the found shows after filtering them.  This method
    # actually fires any HTTP queries if it hasn't been done already.
    #
    # @return [Array]
    def all
      return [] if @source.nil?
      self.load
    end

    def each
      self.load.each { |item| yield item }
    end

    def size
      self.load.size
    end

    protected

    # Load RSS data from @source and apply filters on them.
    # @return [Array]
    def load
      @source.feed! unless @source.fed?
      @_show_list_cache ||= apply_filters
    end

    # Turn a Hash filter into a proc based filter.
    # @param [String, Regexp] show   Show name, or Regexp
    # @param [Hash]           filter Filter expression
    # @return [Array] A regular filter array where the first element is the show
    #                 name, and the second a Proc
    # @example
    #   expand_hash_filter 'Show Name', {description: /Season: 5/}
    #   # => [ 'Show Name', <Proc: ... > ]
    def expand_hash_filter show, filter
      key = filter[0][0]
      val = filter[0][1]
      method = val.respond_to?(:match) ? :match : :==
      [ show, proc { |x| x[key].send method, val } ]
    end

    # Apply @filters to the set, that is: remove every result that does not
    # satisfy it.
    # @return [Ezrss::ResultSet]
    # @return [Array]
    def apply_filters
      @filters.each do |filter|
        # Filter every show
        if filter[0].respond_to?(:match)
          apply_filter @results.keys, &filter[1]
        # Filter one show
        else
          apply_filter filter[0], &filter[1]
        end
      end

      @results.values.flatten
    end

    # Apply a filter proc on every show name in keys.
    #
    # @param [String, Array] names  A show name (String), or an Array of names.
    # @param [Proc]          filter Filter proc
    # @return [Array]
    def apply_filter names, &filter
      names = [names] unless names.respond_to?(:each)
      names.sort.uniq.each { |x| @results[x].select! &filter }
    end
  end
end
