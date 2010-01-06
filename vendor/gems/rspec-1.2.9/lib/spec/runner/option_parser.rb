require 'optparse'
require 'stringio'

module Spec
  module Runner
    class OptionParser < ::OptionParser
      class << self
        def parse(args, err, out)
          parser = new(err, out)
          parser.parse(args)
          parser.options
        end

        def spec_command?
          $0.split('/').last == 'spec'
        end
      end

      attr_reader :options

      OPTIONS = {
        :pattern => ["-p", "--pattern [PATTERN]","Limit files loaded to those matching this pattern. Defaults to '**/*_spec.rb'",
                                                 "Separate multiple patterns with commas.",
                                                 "Applies only to directories named on the command line (files",
                                                 "named explicitly on the command line will be loaded regardless)."],
        :diff =>    ["-D", "--diff [FORMAT]","Show diff of objects that are expected to be equal when they are not",
                                             "Builtin formats: unified|u|context|c",
                                             "You can also specify a custom differ class",
                                             "(in which case you should also specify --require)"],
        :colour =>  ["-c", "--colour", "--color", "Show coloured (red/green) output"],
        :example => ["-e", "--example [NAME|FILE_NAME]",  "Execute example(s) with matching name(s). If the argument is",
                                                          "the path to an existing file (typically generated by a previous",
                                                          "run using --format failing_examples:file.txt), then the examples",
                                                          "on each line of that file will be executed. If the file is empty,",
                                                          "all examples will be run (as if --example was not specified).",
                                                          " ",
                                                          "If the argument is not an existing file, then it is treated as",
                                                          "an example name directly, causing RSpec to run just the example",
                                                          "matching that name"],
        :specification => ["-s", "--specification [NAME]", "DEPRECATED - use -e instead", "(This will be removed when autotest works with -e)"],
        :line => ["-l", "--line LINE_NUMBER", Integer, "Execute example group or example at given line.",
                                                       "(does not work for dynamically generated examples)"],
        :format => ["-f", "--format FORMAT[:WHERE]","Specifies what format to use for output. Specify WHERE to tell",
                                                    "the formatter where to write the output. All built-in formats",
                                                    "expect WHERE to be a file name, and will write to $stdout if it's",
                                                    "not specified. The --format option may be specified several times",
                                                    "if you want several outputs",
                                                    " ",
                                                    "Builtin formats:",
                                                    "silent|l                 : No output",                                                    "progress|p               : Text-based progress bar",
                                                    "profile|o                : Text-based progress bar with profiling of 10 slowest examples",
                                                    "specdoc|s                : Code example doc strings",
                                                    "nested|n                 : Code example doc strings with nested groups indented",
                                                    "html|h                   : A nice HTML report",
                                                    "failing_examples|e       : Write all failing examples - input for --example",
                                                    "failing_example_groups|g : Write all failing example groups - input for --example",
                                                    " ",
                                                    "FORMAT can also be the name of a custom formatter class",
                                                    "(in which case you should also specify --require to load it)"],
        :require => ["-r", "--require FILE", "Require FILE before running specs",
                                             "Useful for loading custom formatters or other extensions.",
                                             "If this option is used it must come before the others"],
        :backtrace => ["-b", "--backtrace", "Output full backtrace"],
        :loadby => ["-L", "--loadby STRATEGY", "Specify the strategy by which spec files should be loaded.",
                                               "STRATEGY can currently only be 'mtime' (File modification time)",
                                               "By default, spec files are loaded in alphabetical order if --loadby",
                                               "is not specified."],
        :reverse => ["-R", "--reverse", "Run examples in reverse order"],
        :timeout => ["-t", "--timeout FLOAT", "Interrupt and fail each example that doesn't complete in the",
                                              "specified time"],
        :heckle => ["-H", "--heckle CODE", "If all examples pass, this will mutate the classes and methods",
                                           "identified by CODE little by little and run all the examples again",
                                           "for each mutation. The intent is that for each mutation, at least",
                                           "one example *should* fail, and RSpec will tell you if this is not the",
                                           "case. CODE should be either Some::Module, Some::Class or",
                                           "Some::Fabulous#method}"],
        :dry_run => ["-d", "--dry-run", "Invokes formatters without executing the examples."],
        :options_file => ["-O", "--options PATH", "Read options from a file"],
        :generate_options => ["-G", "--generate-options PATH", "Generate an options file for --options"],
        :runner => ["-U", "--runner RUNNER", "Use a custom Runner."],
        :debug => ["-u", "--debugger", "Enable ruby-debugging."],
        :drb => ["-X", "--drb", "Run examples via DRb. (For example against script/spec_server)"],
        :version => ["-v", "--version", "Show version"],
        :help => ["-h", "--help", "You're looking at it"]
      }

      def initialize(err, out)
        super()
        @error_stream = err
        @out_stream = out
        @options = Options.new(@error_stream, @out_stream)

        @file_factory = File

        self.banner = "Usage: spec (FILE(:LINE)?|DIRECTORY|GLOB)+ [options]"
        self.separator ""
        on(*OPTIONS[:pattern])          {|pattern| @options.filename_pattern = pattern}
        on(*OPTIONS[:diff])             {|diff| @options.parse_diff(diff)}
        on(*OPTIONS[:colour])           {@options.colour = true}
        on(*OPTIONS[:example])          {|example| @options.parse_example(example)}
        on(*OPTIONS[:specification])    {|example| @options.parse_example(example)}
        on(*OPTIONS[:line])             {|line_number| @options.line_number = line_number.to_i}
        on(*OPTIONS[:format])           {|format| @options.parse_format(format)}
        on(*OPTIONS[:require])          {|requires| invoke_requires(requires)}
        on(*OPTIONS[:backtrace])        {@options.backtrace_tweaker = NoisyBacktraceTweaker.new}
        on(*OPTIONS[:loadby])           {|loadby| @options.loadby = loadby}
        on(*OPTIONS[:reverse])          {@options.reverse = true}
        on(*OPTIONS[:timeout])          {|timeout| @options.timeout = timeout.to_f}
        on(*OPTIONS[:heckle])           {|heckle| @options.load_heckle_runner(heckle)}
        on(*OPTIONS[:dry_run])          {@options.dry_run = true}
        on(*OPTIONS[:options_file])     {|options_file|}
        on(*OPTIONS[:generate_options]) {|options_file|}
        on(*OPTIONS[:runner])           {|runner|  @options.user_input_for_runner = runner}
        on(*OPTIONS[:debug])            {@options.debug = true}
        on(*OPTIONS[:drb])              {}
        on(*OPTIONS[:version])          {parse_version}
        on("--autospec")                {@options.autospec = true}
        on_tail(*OPTIONS[:help])        {parse_help}
      end

      def order!(argv, &blk)
        @argv = argv.dup
        @argv = (@argv.empty? & self.class.spec_command?) ? ['--help'] : @argv

        # Parse options file first
        parse_file_options(:options_file, :parse_options_file)

        @options.argv = @argv.dup
        return if parse_file_options(:generate_options, :write_options_file)
        return if parse_drb

        super(@argv) do |file|
          if file =~ /^(.+):(\d+)$/
            file = $1
            @options.line_number = $2.to_i
          end

          @options.files << file
          blk.call(file) if blk
        end

        @options
      end

    protected

      def invoke_requires(requires)
        requires.split(",").each do |file|
          require file
        end
      end

      def parse_file_options(option_name, action)
        # Remove the file option and the argument before handling the file
        options_file = nil
        options_list = OPTIONS[option_name][0..1]
        options_list[1].gsub!(" PATH", "")
        options_list.each do |option|
          if index = @argv.index(option)
            @argv.delete_at(index)
            options_file = @argv.delete_at(index)
          end
        end
        
        if options_file.nil? &&
           File.exist?('spec/spec.opts') &&
           !@argv.any?{|a| a =~ /^\-/ }
             options_file = 'spec/spec.opts'
        end

        if options_file
          send(action, options_file)
          return true
        else
          return false
        end
      end

      def parse_options_file(options_file)
        option_file_args = File.readlines(options_file).map {|l| l.chomp.split " "}.flatten
        @argv.push(*option_file_args)
      end

      def write_options_file(options_file)
        File.open(options_file, 'w') do |io|
          io.puts @argv.join("\n")
        end
        @out_stream.puts "\nOptions written to #{options_file}. You can now use these options with:"
        @out_stream.puts "spec --options #{options_file}"
        @options.examples_should_not_be_run
      end

      def parse_drb
        argv = @options.argv
        is_drb = false
        is_drb ||= argv.delete(OPTIONS[:drb][0])
        is_drb ||= argv.delete(OPTIONS[:drb][1])
        return false unless is_drb
        if DrbCommandLine.run(self.class.parse(argv, @error_stream, @out_stream))
          @options.examples_should_not_be_run
          true
        else
          @error_stream.puts "Running specs locally:"
          false
        end
      end

      def parse_version
        @out_stream.puts ::Spec::VERSION::SUMMARY
        exit if stdout?
      end

      def parse_help
        @out_stream.puts self
        exit if stdout?
      end

      def stdout?
        @out_stream == $stdout
      end
    end
  end
end
