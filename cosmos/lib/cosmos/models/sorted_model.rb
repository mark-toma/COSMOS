# encoding: ascii-8bit

# Copyright 2022 Ball Aerospace & Technologies Corp.
# All Rights Reserved.
#
# This program is free software; you can modify and/or redistribute it
# under the terms of the GNU Affero General Public License
# as published by the Free Software Foundation; version 3 with
# attribution addendums as found in the LICENSE.txt
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# This program may also be used under the terms of a commercial or
# enterprise edition license of COSMOS if purchased from the
# copyright holder

# https://www.rubydoc.info/gems/redis/Redis/Commands/SortedSets
# https://redis.io/docs/manual/data-types/data-types-tutorial/#sorted-sets

require 'cosmos/models/model'
require 'cosmos/topics/calendar_topic'

module Cosmos
  # Put these under the Cosmos module so they are easily accessed in the controller as
  # Cosmos::SortedError vs Cosmos::SortedModel::Error
  class SortedError < StandardError; end
  class SortedInputError < SortedError; end
  class SortedOverlapError < SortedError; end

  class SortedModel < Model
    SORTED_TYPE = 'sorted'.freeze # To be overriden by base class
    PRIMARY_KEY = '__SORTED'.freeze # To be overriden by base class

    # MUST be overriden by any subclasses
    def self.pk(scope)
      "#{scope}#{PRIMARY_KEY}"
    end

    # @return [String|nil] String of the saved json or nil if start not found
    def self.get(start:, scope:)
      result = Store.zrangebyscore(self.pk(scope), start, start, :limit => [0, 1])
      return JSON.parse(result[0]) unless result.empty?
      nil
    end

    # @return [Array<Hash>] Array up to the limit of the models (as Hash objects) stored under the primary key
    def self.all(scope:, limit: 100)
      result = Store.zrange(self.pk(scope), 0, -1, :limit => [0, limit])
      result.map { |item| JSON.parse(item) }
    end

    # @return [String|nil] json or nil if metadata empty
    def self.get_current_value(scope:)
      start = Time.now.to_i
      array = Store.zrevrangebyscore(self.pk(scope), start, '-inf', :limit => [0, 1])
      return nil if array.empty?
      return array[0]
    end

    # @param start [Integer] Start time to return values (inclusive)
    # @param stop [Integer] Stop time to return values (inclusive)
    # @return [Array|nil] Array up to 100 of this model or empty array
    def self.range(start:, stop:, scope:, limit: 100)
      if start > stop
        raise SortedInputError.new "start: #{start} must be before stop: #{stop}"
      end
      result = Store.zrangebyscore(self.pk(scope), start, stop, :limit => [0, limit])
      result.map { |item| JSON.parse(item) }
    end

    # @return [Integer] count of the members stored under the primary key
    def self.count(scope:)
      Store.zcard(self.pk(scope))
    end

    # Remove member from a sorted set
    # @return [Integer] count of the members removed, 0 if not found
    def self.destroy(scope:, start:)
      Store.zremrangebyscore(self.pk(scope), start, start)
    end

    # Remove members from min to max of the sorted set.
    # @return [Integer] count of the members removed
    def self.range_destroy(scope:, start:, stop:)
      Store.zremrangebyscore(self.pk(scope), start, stop)
    end

    attr_reader :start

    # @param [Integer] start - start used to store data
    # @param [String] scope - Cosmos scope to track event to
    # @param [Anything] kwargs - Any kwargs to store in the JSON
    def initialize(start:, scope:, type: SORTED_TYPE, **kwargs)
      # Name becomes the start in the base class
      super(self.class.pk(scope), name: start.to_s, scope: scope, **kwargs)
      @type = type # For the as_json, from_json round trip
      @start = validate_start(start, update: false)
    end

    # start MUST be a positive integer
    def validate_start(start, update:)
      unless start.is_a?(Integer)
        raise SortedInputError.new "start must be integer: #{start}"
      end
      if start.to_i < 0
        raise SortedInputError.new "start must be positive: #{start}"
      end
      if !update and self.class.get(start: start, scope: @scope)
        raise SortedOverlapError.new "no metadata can overlap, existing data at #{start}"
      end
      start.to_i
    end

    # Update the Redis hash at primary_key based on the initial passed start
    # The member is set to the JSON generated via calling as_json
    def create
      if self.class.get(start: @start, scope: @scope)
        raise SortedOverlapError.new "no sorted start can overlap, start: #{@start}"
      end
      @updated_at = Time.now.to_nsec_from_epoch
      Store.zadd(@primary_key, @start, JSON.generate(as_json()))
      notify(kind: 'created')
    end

    # Update the Redis hash at primary_key by removing the current item
    # and creating a new item
    def update(start:)
      old_start = @start
      @updated_at = Time.now.to_nsec_from_epoch
      @start = validate_start(start, update: true)
      self.class.destroy(scope: @scope, start: old_start)
      create()
      notify(kind: 'updated', extra: old_start)
    end

    # destroy the activity from the redis database
    def destroy
      self.class.destroy(scope: @scope, start: @start)
      notify(kind: 'deleted')
    end

    # @return [] update the redis stream / timeline topic that something has changed
    def notify(kind:, extra: nil)
      notification = {
        'data' => JSON.generate(as_json()),
        'kind' => kind,
        'type' => 'calendar',
      }
      notification['extra'] = extra unless extra.nil?
      begin
        CalendarTopic.write_entry(notification, scope: @scope)
      rescue StandardError => e
        raise SortedError.new "Failed to write to stream: #{notification}, #{e}"
      end
    end

    # @return [Hash] JSON encoding of this model
    def as_json
      { **super(),
        'start' => @start,
        'type' => SORTED_TYPE,
      }
    end
  end
end
