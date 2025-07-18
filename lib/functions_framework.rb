# Copyright 2020 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require "logger"

require "cloud_events"

require "functions_framework/function"
require "functions_framework/legacy_event_converter"
require "functions_framework/registry"
require "functions_framework/version"

##
# The Functions Framework for Ruby.
#
# Functions Framework is an open source framework for writing lightweight,
# portable Ruby functions that run in a serverless environment. For general
# information about the Functions Framework, see
# https://github.com/GoogleCloudPlatform/functions-framework.
# To get started with the functions framework for Ruby, see
# https://github.com/GoogleCloudPlatform/functions-framework-ruby for basic
# examples.
#
# ## Inside the FunctionsFramework module
#
# The FunctionsFramework module includes the main entry points for the
# functions framework. Use the {FunctionsFramework.http},
# {FunctionsFramework.event}, or {FunctionsFramework.cloud_event} methods to
# define functions. To serve functions via a web service, invoke the
# `functions-framework-ruby` executable, or use the {FunctionsFramework.start}
# or {FunctionsFramework.run} methods.
#
# ## Internal modules
#
# Here is a roadmap to the internal modules in the Ruby functions framework.
#
#  *  {FunctionsFramework::CLI} is the implementation of the
#     `functions-framework-ruby` executable. Most apps will not need to interact
#     with this class directly.
#  *  {FunctionsFramework::Function} is the internal representation of a
#     function, indicating the type of function (http or cloud event), the
#     name of the function, and the block of code implementing it. Most apps
#     do not need to interact with this class directly.
#  *  {FunctionsFramework::Registry} looks up functions by name. When you
#     define a set of named functions, they are added to a registry, and when
#     you start a server and specify the target function by name, it is looked
#     up from the registry. Most apps do not need to interact with this class
#     directly.
#  *  {FunctionsFramework::Server} is a web server that makes a function
#     available via HTTP. It wraps the Puma web server and runs a specific
#     {FunctionsFramework::Function}. Many apps can simply run the
#     `functions-framework-ruby` executable to spin up a server. However, if you
#     need closer control over your execution environment, you can use the
#     {FunctionsFramework::Server} class to run a server. Note that, in most
#     cases, it is easier to use the {FunctionsFramework.start} or
#     {FunctionsFramework.run} wrapper methods rather than instantiate a
#     {FunctionsFramework::Server} class directly.
#  *  {FunctionsFramework::Testing} provides helpers that are useful when
#     writing unit tests for functions.
#
module FunctionsFramework
  @global_registry = Registry.new
  @logger = ::Logger.new $stderr
  @logger.level = ::Logger::INFO

  ##
  # The default target function name. If you define a function without
  # specifying a name, or run the framework without giving a target, this name
  # is used.
  #
  # @return [String]
  #
  DEFAULT_TARGET = "function".freeze

  ##
  # The default source file path. The CLI loads functions from this file if no
  # source file is given explicitly.
  #
  # @return [String]
  #
  DEFAULT_SOURCE = "./app.rb".freeze

  ##
  # The CloudEvents implementation was extracted to become the official
  # CloudEvents SDK. This alias is left here for backward compatibility.
  #
  CloudEvents = ::CloudEvents

  class << self
    ##
    # The "global" registry that holds events defined by the
    # {FunctionsFramework} class methods.
    #
    # @return [FunctionsFramework::Registry]
    #
    attr_accessor :global_registry

    ##
    # A "global" logger that is used by the framework's web server, and can
    # also be used by functions.
    #
    # @return [Logger]
    #
    attr_accessor :logger

    ##
    # Define a function that responds to HTTP requests.
    #
    # You must provide a name for the function, and a block that implements the
    # function. The block should take a single `Rack::Request` argument. It
    # should return one of the following:
    #  *  A standard 3-element Rack response array. See
    #     https://github.com/rack/rack/blob/main/SPEC.rdoc
    #  *  A `Rack::Response` object.
    #  *  A simple String that will be sent as the response body.
    #  *  A Hash object that will be encoded as JSON and sent as the response
    #     body.
    #
    # ## Example
    #
    #     FunctionsFramework.http "my-function" do |request|
    #       "I received a request for #{request.url}"
    #     end
    #
    # @param name [String] The function name. Defaults to {DEFAULT_TARGET}.
    # @return [self]
    #
    def http(name = DEFAULT_TARGET, &)
      global_registry.add_http(name, &)
      self
    end

    ## Define a Typed function that responds to HTTP requests.
    #
    # You must provide a name for the function, and a block that implements the
    # function. The block should take a single argument representing the request
    # payload. If a `request_type` is provided, the argument object will be of
    # the given decoded type; otherwise, it will be a JSON hash. The  block
    # should return a JSON hash or an object that implements `#to_json`.
    #
    # ## Example
    #     FunctionsFramework.typed "my-sum-function" do |add_request|
    #       {sum: add_request["num1"] + add_response["num2"]}
    #     end
    #
    # ## Example with Type
    #     FunctionsFramework.typed "identity",
    #                             request_class: MyCustomType do |custom_type|
    #       custom_type
    #     end
    #
    # @param name [String] The function name. Defaults to {DEFAULT_TARGET}
    # @param request_class [#decode_json] An optional class which will be used to
    #        decode the request if it implements a `decode_json` static method.
    # @return [self]
    #
    def typed(name = DEFAULT_TARGET, request_class: nil, &)
      global_registry.add_typed(name, request_class: request_class, &)
      self
    end

    ##
    # Define a function that responds to CloudEvents.
    #
    # You must provide a name for the function, and a block that implements the
    # function. The block should take one argument: the event object of type
    # [`CloudEvents::Event`](https://cloudevents.github.io/sdk-ruby/latest/CloudEvents/Event).
    # Any return value is ignored.
    #
    # ## Example
    #
    #     FunctionsFramework.cloud_event "my-function" do |event|
    #       FunctionsFramework.logger.info "Event data: #{event.data.inspect}"
    #     end
    #
    # @param name [String] The function name. Defaults to {DEFAULT_TARGET}.
    # @return [self]
    #
    def cloud_event(name = DEFAULT_TARGET, &)
      global_registry.add_cloud_event(name, &)
      self
    end

    ##
    # Define a server startup task as a block. This is useful for initializing shared
    # resources that should be accessible across all function invocations in
    # this Ruby VM.
    #
    # Startup tasks are run just before a server starts. All startup tasks are
    # guaranteed to complete before any function executes. However, they are
    # run only when preparing to run functions. They are not run, for example,
    # if an app is loaded to verify its integrity during deployment.
    #
    # Startup tasks are passed the {FunctionsFramework::Function} identifying
    # the function to execute, and have no return value.
    #
    # @return [self]
    #
    def on_startup(&)
      global_registry.add_startup_task(&)
      self
    end

    ##
    # Run startup tasks, then start the functions framework server in the
    # background. The startup tasks and target function will be looked up in
    # the global registry.
    #
    # @param target [FunctionsFramework::Function,String] The function to run,
    #     or the name of the function to look up in the global registry.
    # @yield [FunctionsFramework::Server::Config] A config object that can be
    #     manipulated to configure the server.
    # @return [FunctionsFramework::Server]
    #
    def start(target, &)
      require "functions_framework/server"
      if target.is_a? ::FunctionsFramework::Function
        function = target
      else
        function = global_registry[target]
        raise ::ArgumentError, "Undefined function: #{target.inspect}" if function.nil?
      end
      globals = function.populate_globals
      server = Server.new(function, globals, &)
      global_registry.startup_tasks.each do |task|
        task.call function, globals: globals, logger: server.config.logger
      end
      globals.freeze
      server.respond_to_signals
      server.start
    end

    ##
    # Run the functions framework server and block until it stops. The server
    # will look up the given target function name in the global registry.
    #
    # @param target [FunctionsFramework::Function,String] The function to run,
    #     or the name of the function to look up in the global registry.
    # @yield [FunctionsFramework::Server::Config] A config object that can be
    #     manipulated to configure the server.
    # @return [self]
    #
    def run(target, &)
      server = start(target, &)
      server.wait_until_stopped
      self
    end
  end
end
