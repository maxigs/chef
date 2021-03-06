#
# Author:: Adam Jacob (<adam@opscode.com>)
# Author:: Christopher Walters (<cw@opscode.com>)
# Author:: Christopher Brown (<cb@opscode.com>)
# Author:: Tim Hinderliter (<tim@opscode.com>)
# Copyright:: Copyright (c) 2008-2010 Opscode, Inc.
# License:: Apache License, Version 2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# 
#     http://www.apache.org/licenses/LICENSE-2.0
# 
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require 'chef/config'
require 'chef/mixin/params_validate'
require 'chef/log'
require 'chef/rest'
require 'chef/platform'
require 'chef/node'
require 'chef/role'
require 'chef/file_cache'
require 'chef/run_context'
require 'chef/runner'
require 'chef/cookbook/cookbook_collection'
require 'chef/cookbook/file_vendor'
require 'chef/cookbook/file_system_file_vendor'
require 'chef/cookbook/remote_file_vendor'
require 'ohai'

class Chef
  class Client
    # TODO: timh/cw: 5-19-2010: json_attribs should be moved to RunContext?
    attr_accessor :node, :registration, :json_attribs, :node_name, :ohai, :rest, :runner
    attr_reader :node_exists
    
    # Creates a new Chef::Client.
    def initialize()
      @node = nil
      @registration = nil
      @json_attribs = nil
      @node_name = nil
      @node_exists = true
      @runner = nil
      @ohai = Ohai::System.new
      Chef::Log.verbose = Chef::Config[:verbose_logging]
      Mixlib::Authentication::Log.logger = Ohai::Log.logger = Chef::Log.logger
      @ohai_has_run = false
    end
    
    # Do a full run for this Chef::Client.  Calls:
    #
    #  * run_ohai - Collect information about the system
    #  * build_node - Get the last known state, merge with local changes
    #  * register - If not in solo mode, make sure the server knows about this client
    #  * sync_cookbooks - If not in solo mode, populate the local cache with the node's cookbooks
    #  * converge - Bring this system up to date
    #
    # === Returns
    # true:: Always returns true.
    def run
      self.runner = nil
      run_context = nil

      run_ohai
      determine_node_name
      register unless Chef::Config[:solo]
      build_node
      
      begin
        start_time = Time.now
        Chef::Log.info("Starting Chef Run")
        
        if Chef::Config[:solo]
          Chef::Cookbook::FileVendor.on_create { |manifest| Chef::Cookbook::FileSystemFileVendor.new(manifest) }
          run_context = Chef::RunContext.new(node, Chef::CookbookCollection.new(Chef::CookbookLoader.new))
          assert_cookbook_path_not_empty(run_context)
          converge(run_context)
        else
          # Keep track of the filenames that we use in both eager cookbook
          # downloading (during sync_cookbooks) and lazy (during the run
          # itself, through FileVendor). After the run is over, clean up the
          # cache.
          valid_cache_entries = Hash.new
          
          save_node

          # Sync_cookbooks eagerly loads all files except files and templates.
          # It returns the cookbook_hash -- the return result from
          # /nodes/#{nodename}/cookbooks -- which we will use for our
          # run_context.
          Chef::Cookbook::FileVendor.on_create { |manifest| Chef::Cookbook::RemoteFileVendor.new(manifest, rest, valid_cache_entries) }
          cookbook_hash = sync_cookbooks(valid_cache_entries)
          run_context = Chef::RunContext.new(node, Chef::CookbookCollection.new(cookbook_hash))
          
          assert_cookbook_path_not_empty(run_context)
          save_node
          
          converge(run_context)
          save_node
          
          cleanup_file_cache(valid_cache_entries)
        end
        
        end_time = Time.now
        elapsed_time = end_time - start_time
        Chef::Log.info("Chef Run complete in #{elapsed_time} seconds")
        run_report_handlers(start_time, end_time, elapsed_time) 
        true
      rescue Exception => e
        run_exception_handlers(node, runner ? runner : run_context, start_time, end_time, elapsed_time, e)
        Chef::Log.error("Re-raising exception: #{e.class} - #{e.message}\n#{e.backtrace.join("\n  ")}")
        raise
      end
    end

    def run_report_handlers(start_time, end_time, elapsed_time)
      if Chef::Config[:report_handlers].length > 0
        Chef::Log.info("Running report handlers")
        Chef::Config[:report_handlers].each do |handler|
          handler.report(node, runner, start_time, end_time, elapsed_time)
        end
        Chef::Log.info("Report handlers complete")
      end
    end

    def run_exception_handlers(node, runner, start_time, end_time, elapsed_time, exception)
      if Chef::Config[:exception_handlers].length > 0
        end_time   ||= Time.now
        elapsed_time ||= end_time - start_time 
        Chef::Log.error("Received exception: #{exception.message}")
        Chef::Log.error("Running exception handlers")
        Chef::Config[:exception_handlers].each do |handler|
          handler.report(node, runner, start_time, end_time, elapsed_time, exception)
        end
        Chef::Log.error("Exception handlers complete")
      end
    end
    
    def run_ohai
      if ohai.keys
        ohai.refresh_plugins
      else
        ohai.all_plugins
      end
    end

    def determine_node_name
      unless node_name
        if Chef::Config[:node_name]
          @node_name = Chef::Config[:node_name]
        else
          @node_name = ohai[:fqdn] ? ohai[:fqdn] : ohai[:hostname]
          Chef::Config[:node_name] = node_name
        end

        raise RuntimeError, "Unable to determine node name from ohai" unless node_name
      end
      node_name
    end
    
    # Builds a new node object for this client.  Starts with querying for the FQDN of the current
    # host (unless it is supplied), then merges in the facts from Ohai.
    #
    # === Returns
    # node<Chef::Node>:: Returns the created node object, also stored in @node
    def build_node
      Chef::Log.debug("Building node object for #{@node_name}")
      
      unless Chef::Config[:solo]
        begin
          @node = rest.get_rest("nodes/#{@node_name}")
        rescue Net::HTTPServerException => e
          raise unless e.message =~ /^404/
        end
      end
      
      unless node
        @node_exists = false
        @node = Chef::Node.new
        @node.name(node_name)
      end

      @node.prepare_for_run(ohai.data, @json_attribs)
      # Need to nil-ify the json attribs so they are not applied on subsequent runs
      @json_attribs = nil

      @node
    end

    # 
    # === Returns
    # rest<Chef::REST>:: returns Chef::REST connection object
    def register
      if File.exists?(Chef::Config[:client_key])
        Chef::Log.debug("Client key #{Chef::Config[:client_key]} is present - skipping registration")
      else
        Chef::Log.info("Client key #{Chef::Config[:client_key]} is not present - registering")
        Chef::REST.new(Chef::Config[:client_url], Chef::Config[:validation_client_name], Chef::Config[:validation_key]).register(node_name, Chef::Config[:client_key])
      end
      # We now have the client key, and should use it from now on.
      self.rest = Chef::REST.new(Chef::Config[:chef_server_url], node_name, Chef::Config[:client_key])
    end
    
    # Synchronizes all the cookbooks from the chef-server.
    #
    # === Returns
    # true:: Always returns true
    def sync_cookbooks(valid_cache_entries)
      Chef::Log.debug("Synchronizing cookbooks")
      cookbook_hash = rest.get_rest("nodes/#{node_name}/cookbooks")
      Chef::Log.debug("Cookbooks to load: #{cookbook_hash.inspect}")
      
      # Remove all cookbooks no longer relevant to this node
      Chef::FileCache.find(File.join(%w{cookbooks ** *})).each do |cache_file|
        cache_file =~ /^cookbooks\/([^\/]+)\//
        unless cookbook_hash.has_key?($1)
          Chef::Log.info("Removing #{cache_file} from the cache; its cookbook is no longer needed on this client.")
          Chef::FileCache.delete(cache_file) 
        end
      end

      # Synchronize each of the node's cookbooks, and add to the
      # valid_cache_entries hash.
      cookbook_hash.values.each do |cookbook|
        sync_cookbook_file_cache(cookbook, valid_cache_entries)
      end

      # register the file cache path in the cookbook path so that CookbookLoader actually picks up the synced cookbooks
      Chef::Config[:cookbook_path] = File.join(Chef::Config[:file_cache_path], "cookbooks")
      
      cookbook_hash
    end
    
    # Update the file caches for a given cache segment.  Takes a segment name
    # and a hash that matches one of the cookbooks/_attribute_files style
    # remote file listings.
    #
    # === Parameters
    # cookbook<Chef::Cookbook>:: The cookbook to update
    # valid_cache_entries<Hash>:: Out-param; Added to this hash are the files that 
    # were referred to by this cookbook
    def sync_cookbook_file_cache(cookbook, valid_cache_entries)
      Chef::Log.debug("Synchronizing cookbook #{cookbook.name}")

      # files and templates are lazily loaded, and will be done later.
      eager_segments = Array(Chef::CookbookVersion::COOKBOOK_SEGMENTS)
      eager_segments.delete(:files)
      eager_segments.delete(:templates)
      
      eager_segments.each do |segment|
        segment_filenames = Array.new
        cookbook.manifest[segment].each do |manifest_record|
          # segment = cookbook segment
          # remote_list = list of file hashes
          #
          # We need the list of known good attribute files, so we can delete any that are
          # just laying about.
        
          cache_filename = File.join("cookbooks", cookbook.name, manifest_record['path'])
          valid_cache_entries[cache_filename] = true

          current_checksum = nil
          if Chef::FileCache.has_key?(cache_filename)
            current_checksum = Chef::CookbookVersion.checksum_cookbook_file(Chef::FileCache.load(cache_filename, false))
          end
          
          # If the checksums are different between on-disk (current) and on-server
          # (remote, per manifest), do the update. This will also execute if there
          # is no current checksum.
          if current_checksum != manifest_record['checksum']
            raw_file = rest.get_rest(manifest_record[:url], true)
            
            Chef::Log.info("Storing updated #{cache_filename} in the cache.")
            Chef::FileCache.move_to(raw_file.path, cache_filename)
          else
            Chef::Log.debug("Not storing #{cache_filename}, as the cache is up to date.")
          end
          
          # make the segment filenames a full path.
          full_path_cache_filename = Chef::FileCache.load(cache_filename, false)
          segment_filenames << full_path_cache_filename
        end
        
        # replace segment filenames with a full-path one.
        if segment.to_sym == :recipes
          cookbook.recipe_filenames = segment_filenames
        elsif segment.to_sym == :attributes
          cookbook.attribute_filenames = segment_filenames
        else
          cookbook.segment_filenames(segment).replace(segment_filenames)
        end
      end
    end
    
    def cleanup_file_cache(valid_cache_entries)
      # Delete each file in the cache that we didn't encounter in the
      # manifest.
      Chef::FileCache.find(File.join(%w{cookbooks ** *})).each do |cache_filename|
        unless valid_cache_entries[cache_filename]
          Chef::Log.info("Removing #{cache_filename} from the cache; it is no longer on the server.")
          Chef::FileCache.delete(cache_filename)
        end
      end
    end

    # Updates the current node configuration on the server.
    #
    # === Returns
    # Chef::Node - the current node
    def save_node
      Chef::Log.debug("Saving the current state of node #{node_name}")
      if node_exists
        @node = @node.save
      else
        result = rest.post_rest("nodes", node)
        @node_exists = true
        @node = rest.get_rest(result['uri'])
      end
    end

    # Converges the node.
    #
    # === Returns
    # true:: Always returns true
    def converge(run_context)
      Chef::Log.debug("Converging node #{node_name}")
      self.runner = Chef::Runner.new(run_context)
      runner.converge
      true
    end
    
    private
    
    def directory_not_empty?(path)
      File.exists?(path) && (Dir.entries(path).size > 2)
    end
    
    def is_last_element?(index, object)
      object.kind_of?(Array) ? index == object.size - 1 : true 
    end  
    
    def assert_cookbook_path_not_empty(run_context)
      if Chef::Config[:solo]
        # Check for cookbooks in the path given
        # Chef::Config[:cookbook_path] can be a string or an array
        # if it's an array, go through it and check each one, raise error at the last one if no files are found
        Chef::Log.debug "loading from cookbook_path: #{Array(Chef::Config[:cookbook_path]).map { |path| File.expand_path(path) }.join(', ')}" 
        Array(Chef::Config[:cookbook_path]).each_with_index do |cookbook_path, index|
          if directory_not_empty?(cookbook_path)
            break
          else
            msg = "No cookbook found in #{Chef::Config[:cookbook_path].inspect}, make sure cookboook_path is set correctly."
            Chef::Log.fatal(msg)
            raise Chef::Exceptions::CookbookNotFound, msg if is_last_element?(index, Chef::Config[:cookbook_path])
          end
        end
      else
        Chef::Log.warn("Node #{node_name} has an empty run list.") if run_context.node.run_list.empty?
      end

    end
  end
end

