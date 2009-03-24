# encoding: utf-8

# lib/executor.rb
#
# Provides some tools to create “Run Script” commands
# that fancily HTML format stdout/stderr.
#
# Nice features include:
#  • Automatic interactive input.
#  • Automatic Fancy HTML headers
#  • The environment variable TM_ERROR_FD will contain a file descriptor to which HTML-formatted
#    exceptions can be written.
#
# Executor runs best if TextMate.save_current_document is called first.  Doing so ensures
# that TM_FILEPATH contains the path to the contents of your current document, even if the
# current document has not yet been saved, or the file is unwriteable.
#
# Call it like this (you'll get rudimentary htmlification of the executable's output):
#
#   Maude::Executor.run(ENV['TM_SHELL'] || ENV['SHELL'] || 'bash', ENV['TM_FILEPATH'])
#
# Or like this if you want to transform the output yourself:
#
#   Maude::Executor.run(ENV['TM_SHELL'] || ENV['SHELL'] || 'bash', ENV['TM_FILEPATH']) do |str, type|
#     str = htmlize(str)
#     str =  "<span class=\"stderr\">#{htmlize(str)}</span>" if type == :out
#   end
# 
# Your block will be called with type :out or :err.  If you don't want to handle a particular type,
# return nil and Executor will apply basic formatting for you.
#
# Maude::Executor.run also accepts six optional named arguments.
#   :version_args are arguments that will be passed to the executable to generate a version string for use as the page's subtitle.
#   :version_regex is a regular expression to which the resulting version string is passed.
#     The subtitle of the Executor.run output is generated from this match.  By default, this just takes the first line.
#   :version_replace is a string that is used to generate a version string for the page's subtitle from matching :version_regex.
#     The rules of String.sub apply.  By default, this just extracts $1 from the match.
#   :verb describes what the call to Executor is doing.  Default is “Running”.
#   :env is the environment in which the command will be run.  Default is ENV.
#   :script_args are arguments to be passed to the *script* as opposed to the interpreter.  They will
#     be appended after the path to the script in the arguments to the interpreter.
#   :use_hashbang Tells Executor wether to override it's first argument with the current file's #! if that exists.
#     The default is “true”.  Set it to “false” to prevent the hash bang from overriding the interpreter.

%w[tm/process tm/htmloutput tm/require_cmd escape exit_codes io].each { |lib|
  require "#{ENV['TM_SUPPORT_PATH']}/lib/#{lib}"
}

$KCODE = 'u' if RUBY_VERSION < "1.9"

$stdout.sync = true

module Maude
  module Executor
    class << self

      # Maude::Executor.run
      #   Provides an API function for running

      def run(*args, &block)
        block ||= Proc.new {}
        args.flatten!

        options = {:version_args    => ['--version'],
                   :version_regex   => /\A(.*)$/,
                   :version_replace => '\1',
                   :verb            => "Running",
                   :script_args     => [],
                   :use_hashbang    => true}
        
        passthrough_options = [:env, :input, :interactive_input]

        options[:bootstrap] = ENV["TM_BUNDLE_SUPPORT"] + "/bin/bootstrap.sh" unless ENV["TM_BUNDLE_SUPPORT"].nil?

        options.merge! args.pop if args.last.is_a? Hash

        if File.exists?(args[-1]) and options[:use_hashbang] == true
          args[0] = parse_hashbang(args[-1]) || args[0]
        end

        # TODO: checking for an array here because a #! line
        # in the script will cause args[0] set to an array by the previous statement.
        # This array could begin with /usr/bin/env and I'm not sure what require_cmd
        # should do in that case -- Alex Ross
        TextMate.require_cmd(args[0]) unless args[0].is_a?(Array)
        
        version = parse_version(args[0], options)
        
        tm_error_fd_read, tm_error_fd_write = ::IO.pipe
        tm_error_fd_read.fcntl(Fcntl::F_SETFD, 1)
        ENV['TM_ERROR_FD'] = tm_error_fd_write.to_i.to_s

        tm_echo_fd_read, tm_echo_fd_write = ::IO.pipe
        tm_echo_fd_read.fcntl(Fcntl::F_SETFD, 1)
        ENV['TM_INTERACTIVE_INPUT_ECHO_FD'] = tm_echo_fd_write.to_i.to_s

        options[:script_args].each { |arg| args << arg }
        
        TextMate::HTMLOutput.show(:title => "#{options[:verb]} “#{ENV['TM_DISPLAYNAME'] || File.basename(ENV["TM_FILEPATH"])}”…", :sub_title => version, :html_head => script_style_header) do |io|
          
          io << '<div class="executor">'
          
          callback = proc do |str, type|
            str.gsub!(ENV["TM_FILEPATH"], "untitled") if ENV["TM_FILE_IS_UNTITLED"]
            filtered_str = block.call(str,type) if [:err, :out].include? type
            if [:err, :out].include?(type) and not filtered_str.nil?
              io << filtered_str
            else
              str = htmlize(str)
              str = "<span class=\"err\">#{str}</span>" if type == :err
              str = "<span class=\"echo\">#{str}</span>" if type == :echo
              io << str
            end
          end
          
          process_options = {:echo => true, :watch_fds => { :echo => tm_echo_fd_read }}
          passthrough_options.each { |key| process_options[key] = options[key] if options.has_key?(key) }
          
          io << "<!-- » #{args[0,args.length-1].join(" ")} #{ENV["TM_DISPLAYNAME"]} -->"
          
          if options.has_key?(:bootstrap) and File.exists?(options[:bootstrap])
            raise "Bootstrap script is not executable." unless File.executable?(options[:bootstrap])
            args[0,0] = options[:bootstrap] # add the bootstrap script to the front of args
          end
          
          start = Time.now
          process_output_wrapper(io) do
            TextMate::Process.run(args, process_options, &callback)
          end
          finish = Time.now
          
          
          tm_error_fd_write.close
          error = tm_error_fd_read.read
          tm_error_fd_read.close

          if ENV.has_key? "TM_FILE_IS_UNTITLED"
            # replace links to temporary file with links to current (unsaved) file, by removing
            # the url option from any txmt:// links.
            error.gsub!("url=file://#{ENV['TM_FILEPATH']}", '')
            error.gsub!("url=file://#{e_url ENV['TM_FILEPATH']}", '')
            error.gsub!(ENV['TM_FILENAME'], "untitled")
            error.gsub!(e_url(ENV['TM_FILENAME']), "untitled")
          elsif ENV.has_key? 'TM_ORIG_FILEPATH'
            error.gsub!(ENV['TM_FILEPATH'], ENV['TM_ORIG_FILEPATH'])
            error.gsub!(e_url(ENV['TM_FILEPATH']), e_url(ENV['TM_ORIG_FILEPATH']))
            error.gsub!(ENV['TM_FILENAME'], ENV['TM_ORIG_FILENAME'])
            error.gsub!(e_url(ENV['TM_FILENAME']), e_url(ENV['TM_ORIG_FILENAME']))
          end

          io << error
          io << '<div class="controls"><a href="#" onclick="copyOutput(document.getElementById(\'_executor_output\'))">copy output</a></div>'
          

          io << "<div id=\"exception_report\" class=\"framed\">"
          if $?.exited?
            io << format("Program exited with code \##{$?.exitstatus} after %0.2f seconds.", finish-start)
          elsif $?.signaled?
            io << format("Program terminated by uncaught signal \##{$?.termsig} after %0.2f seconds.", finish-start)
          elsif $?.stopped?
            io << format("Program stopped by signal \##{$?.termsig} after %0.2f seconds.", finish-start)
          end
          io << '</div></div>'
        end
      end
      
      def make_project_master_current_document
        if (ENV.has_key?("TM_PROJECT_DIRECTORY") and ENV.has_key?("TM_PROJECT_MASTER") and not ENV["TM_PROJECT_MASTER"] == "")
          proj_dir    = ENV["TM_PROJECT_DIRECTORY"]
          proj_master = ENV["TM_PROJECT_MASTER"]
          if proj_master[0].chr == "/"
            filepath = proj_master
          else
            filepath = "#{proj_dir}/#{proj_master}"
          end
          unless File.exists?(filepath)
            TextMate::HTMLOutput.show(:title => "Bad TM_PROJECT_MASTER!", :sub_title => "") do |io|
              io << "<h2 class=\"warning\">The file suggested by <code>TM_PROJECT_MASTER</code> does not exist.</h2>\n"
              io << "<p>The file “<code>#{filepath}</code>” named by the environment variable <code>TM_PROJECT_MASTER</code> could not be found.  Please unset or correct TM_PROJECT_MASTER.</p>"
            end
            TextMate.exit_show_html
          end
          ENV['TM_FILEPATH']    = filepath
          ENV['TM_FILENAME']    = File.basename filepath
          ENV['TM_DISPLAYNAME'] = File.basename filepath
          Dir.chdir(File.dirname(filepath))
        end
      end

      def parse_hashbang(file)
        $1.chomp.split if /\A#!(.*)$/ =~ File.read(file)
      end

      def parse_version(executable, options)
        out, err = TextMate::Process.run(executable, options[:version_args], :interactive_input => false)
        if options[:version_regex] =~ (out + err)
          return (out + err).sub(options[:version_regex], options[:version_replace])
        end
      end

      private

      def process_output_wrapper(io)
        io << <<-HTML

<script type="text/javascript" charset="utf-8">document.body.addEventListener("keydown", press, false);</script>

<!-- first box containing version info and script output -->
<pre>
<div id="_executor_output" > <!-- Script output -->
HTML
        yield
        io << <<-HTML
        </div></pre>
        HTML
      end
      
      def script_style_header
        return <<-HTML
<!-- executor javascripts -->
  <script type="text/javascript" charset="utf-8">
  function press(evt) {
     if (evt.keyCode == 67 && evt.ctrlKey == true) {
       TextMate.system("kill -s USR1 #{::Process.pid};", null);
     }
  }
  
  function copyOutput(element) {
    output = element.innerText;
    cmd = TextMate.system('__CF_USER_TEXT_ENCODING=$UID:0x8000100:0x8000100 /usr/bin/pbcopy', function(){});
    cmd.write(output);
    cmd.close();
    element.innerText = 'output copied to clipboard';
  }
  
  </script>
  <!-- end javascript -->
  <style type="text/css">

    div.executor .controls {
      text-align:right;
      float:right;
    }
    div.executor .controls a {
      text-decoration: none;
    }

    div.executor pre em
    {
      font-style: normal;
      color: #FF5600;
    }

    div.executor p#exception strong
    {
      color: #E4450B;
    }

    div.executor p#traceback
    {
      font-size: 8pt;
    }

    div.executor blockquote {
      font-style: normal;
      border: none;
    }

    div.executor table {
      margin: 0;
      padding: 0;
    }

    div.executor td {
      margin: 0;
      padding: 2px 2px 2px 5px;
      font-size: 10pt;
    }

    div.executor div#_executor_output {
      white-space: normal;
      -khtml-nbsp-mode: space;
      -khtml-line-break: after-white-space;
    }

    div#_executor_output .out {  

    }
    div#_executor_output .err {  
      color: red;
    }
    div#_executor_output .echo {
      font-style: italic;
    }
    div#_executor_output .test {
      font-weight: bold;
    }
    div#_executor_output .test.ok {  
      color: green;
    }
    div#_executor_output .test.fail {  
      color: red;
    }
    div#exception_report pre.snippet {
      margin:4pt;
      padding:4pt;
    }
  </style>
HTML
      end
    end
  end
end
