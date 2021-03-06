#
# Author:: Adam Jacob (<adam@opscode.com>)
# Copyright:: Copyright (c) 2008 Opscode, Inc.
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
#

CHEF_CLIENT = File.join(CHEF_PROJECT_ROOT, "chef", "bin", "chef-client")

###
# When
###
When /^I run the chef\-client$/ do
  @log_level ||= ENV["LOG_LEVEL"] ? ENV["LOG_LEVEL"] : "error"
  @chef_args ||= ""
  @config_file ||= File.expand_path(File.join(configdir, 'client.rb'))
  status = Chef::Mixin::Command.popen4(
    "#{File.join(File.dirname(__FILE__), "..", "..", "chef", "bin", "chef-client")} -l #{@log_level} -c #{@config_file} #{@chef_args}") do |p, i, o, e|
    @stdout = o.gets(nil)
    @stderr = e.gets(nil)
  end
  @status = status
end

When /^I run the chef\-client again$/ do
  When "I run the chef-client"
end

When /^I run the chef\-client with '(.+)'$/ do |args|
  @chef_args = args
  When "I run the chef-client"
end

When /^I run the chef\-client with '(.+)' for '(.+)' seconds$/ do |args, run_for|
  @chef_args = args
  When "I run the chef-client for '#{run_for}' seconds"
end

When /^I run the chef\-client for '(.+)' seconds$/ do |run_for|
  cid = Process.fork { 
    sleep run_for.to_i
    Process.kill("INT", /^(.+chef\-client.+\-i.*)$/.match(`ps -ef`).to_s.split[1].to_i)
    exit
  } 
  When 'I run the chef-client'
  Process.wait2(cid)
end

When /^I run the chef\-client at log level '(.+)'$/ do |log_level|
  @log_level = log_level.to_sym
  When "I run the chef-client"
end

When 'I run the chef-client with json attributes' do
  @log_level = :debug
  @chef_args = "-j #{File.join(FEATURES_DATA, 'json_attribs', 'attribute_settings.json')}"
  When "I run the chef-client"
end
  

When /^I run the chef\-client with config file '(.+)'$/ do |config_file|
  @config_file = config_file
  When "I run the chef-client"
end

When /^I run the chef\-client with logging to the file '(.+)'$/ do |log_file|
  
config_data = <<CONFIG
supportdir = File.expand_path(File.join(File.dirname(__FILE__), ".."))
tmpdir = File.expand_path(File.join(File.dirname(__FILE__), "..", "tmp"))

log_level        :debug
log_location     File.join(tmpdir, "silly-monkey.log")
file_cache_path  File.join(tmpdir, "cache")
ssl_verify_mode  :verify_none
registration_url "http://127.0.0.1:4000"
openid_url       "http://127.0.0.1:4000"
template_url     "http://127.0.0.1:4000"
remotefile_url   "http://127.0.0.1:4000"
search_url       "http://127.0.0.1:4000"
role_url         "http://127.0.0.1:4000"
client_url       "http://127.0.0.1:4000"
chef_server_url  "http://127.0.0.1:4000"
validation_client_name "validator"
systmpdir = File.expand_path(File.join(Dir.tmpdir, "chef_integration"))
validation_key   File.join(systmpdir, "validation.pem")
client_key       File.join(systmpdir, "client.pem")
CONFIG
  
  @config_file = File.expand_path(File.join(File.dirname(__FILE__), '..', 'data', 'config', 'client-with-logging.rb'))  
  File.open(@config_file, "w") do |file|
    file.write(config_data)
  end

  self.cleanup_files << @config_file
  
  
  @status = Chef::Mixin::Command.popen4("#{File.join(File.dirname(__FILE__), "..", "..", "chef", "bin", "chef-client")} -c #{@config_file} #{@chef_args}") do |p, i, o, e|
    @stdout = o.gets(nil)
    @stderr = e.gets(nil)
  end
end

###
# Then
###
Then /^the run should exit '(.+)'$/ do |exit_code|
  if ENV['LOG_LEVEL'] == 'debug'
    puts @status.inspect
    puts @status.exitstatus
  end
  begin
    @status.exitstatus.should eql(exit_code.to_i)
  rescue 
    print_output
    raise
  end
  print_output if ENV["LOG_LEVEL"] == "debug"
end

Then /^the run should exit from being signaled$/ do 
  begin
    @status.signaled?.should == true
  rescue 
    print_output
    raise
  end
  print_output if ENV["LOG_LEVEL"] == "debug"
end


def print_output
  puts "--- run stdout:"
  puts @stdout
  puts "--- run stderr:"
  puts @stderr
end

# Matcher for regular expression which uses normal string interpolation for
# the actual (target) value instead of expecting it, as stdout/stderr which
# get matched against may have lots of newlines, which looks ugly when
# inspected, as the newlines show up as \n
class NoInspectMatch
  def initialize(expected_regex)
    @expected_regex = expected_regex
  end
  def matches?(target)
    @target = target
    @target =~ @expected_regex
  end
  def failure_message
    "expected #{@target} should match #{@expected_regex}"
  end
  def negative_failure_message
    "expected #{@target} not to match #{@expected_regex}"
  end
end
def noinspect_match(expected_regex)
  NoInspectMatch.new(expected_regex)
end


Then /^'(.+)' should have '(.+)'$/ do |which, to_match|
  if which == "stdout" || which == "stderr"
    self.instance_variable_get("@#{which}".to_sym).should noinspect_match(/#{to_match}/m)
  else
    self.instance_variable_get("@#{which}".to_sym).should match(/#{to_match}/m)
  end    
end

Then /^'(.+)' should not have '(.+)'$/ do |which, to_match|
  if which == "stdout" || which == "stderr"
    self.instance_variable_get("@#{which}".to_sym).should_not noinspect_match(/#{to_match}/m)
  else
    self.instance_variable_get("@#{which}".to_sym).should_not match(/#{to_match}/m)
  end
end

Then /^'(.+)' should appear on '(.+)' '(.+)' times$/ do |to_match, which, count|
  seen_count = 0
  self.instance_variable_get("@#{which}".to_sym).split("\n").each do |line|
    seen_count += 1 if line =~ /#{to_match}/
  end
  seen_count.should == count.to_i
end

Then "I inspect the contents of the features tmpdir" do
  puts `ls -halpR #{tmpdir}`
end
