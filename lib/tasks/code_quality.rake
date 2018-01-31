desc "Generate security audit and code quality report"
# e.g.: rake code_quality lowest_score=90 max_offenses=100 metrics=stats,rails_best_practices,roodi rails_best_practices_max_offenses=10 roodi_max_offenses=10
task :code_quality => :"code_quality:default" do; end if Rake.application.instance_of?(Rake::Application)
namespace :code_quality do
  task :default => [:summary, :security_audit, :quality_audit, :generate_index] do; end

  # desc "show summary"
  task :summary do
    puts "# Code Quality Report", "\n"
    puts "Generated by code_quality (v#{CodeQuality::VERSION}) @ #{Time.now}", "\n"
  end

  # desc "generate a report index page"
  task :generate_index => :helpers do
    index_path = "tmp/code_quality/index.html"
    generate_index index_path
    # puts "Generate report index to #{index_path}"
    show_in_browser File.realpath(index_path)
  end

  desc "security audit using bundler-audit, brakeman"
  task :security_audit => [:"security_audit:default"] do; end
  namespace :security_audit do
    # default tasks
    task :default => [:bundler_audit, :brakeman, :resources] do; end

    # desc "prepare dir"
    task :prepare => :helpers do
      @report_dir = "tmp/code_quality/security_audit"
      prepare_dir @report_dir

      def report_dir
        @report_dir
      end
    end

    desc "bundler audit"
    task :bundler_audit => :prepare do |task|
      run_audit task, "bundler audit - checks for vulnerable versions of gems in Gemfile.lock" do
        # Update the ruby-advisory-db and check Gemfile.lock
        report = `bundle audit check --update`
        @report_path = "#{report_dir}/bundler-audit-report.txt"
        File.open(@report_path, 'w') {|f| f.write report }
        puts report
        audit_faild "Must fix vulnerabilities ASAP" unless report =~ /No vulnerabilities found/
      end
    end

    desc "brakeman"
    task :brakeman => :prepare do |task|
      require 'json'
      run_audit task, "Brakeman audit - checks Ruby on Rails applications for security vulnerabilities" do
        @report_path = "#{report_dir}/brakeman-report.txt"
        `brakeman -o #{@report_path} -o #{report_dir}/brakeman-report.json`
        puts `cat #{@report_path}`
        report = JSON.parse(File.read("#{report_dir}/brakeman-report.json"))
        audit_faild "There are #{report["errors"].size} errors, must fix them ASAP." if report["errors"].any?
      end
    end

    # desc "resources url"
    task :resources do
      refs = %w{
        https://github.com/presidentbeef/brakeman
        https://github.com/rubysec/bundler-audit
        http://guides.rubyonrails.org/security.html
        https://github.com/hardhatdigital/rails-security-audit
        https://hakiri.io/blog/ruby-security-tools-and-resources
        https://www.netsparker.com/blog/web-security/ruby-on-rails-security-basics/
        https://www.owasp.org/index.php/Ruby_on_Rails_Cheatsheet
      }
      puts "## Security Resources"
      puts refs.map { |url| "  - #{url}" }, "\n"
    end
  end

  desc "code quality audit"
  # e.g.: rake code_quality:quality_audit fail_fast=true
  # options:
  #   fail_fast: to stop immediately if any audit task fails, by default fail_fast=false
  #   generate_index: generate a report index page to tmp/code_quality/quality_audit/index.html, by default generate_index=false
  task :quality_audit => [:"quality_audit:default"] do; end
  namespace :quality_audit do |ns|
    # default tasks
    task :default => [:run_all, :resources] do; end

    desc "run all audit tasks"
    task :run_all => :helpers do
      options = options_from_env(:fail_fast, :generate_index)
      fail_fast = options.fetch(:fail_fast, "false")
      generate_index = options.fetch(:generate_index, "false")
      audit_tasks = [:rubycritic, :rubocop, :metric_fu]
      exc = nil
      audit_tasks.each do |task_name|
        begin
          task = ns[task_name]
          task.invoke
        rescue SystemExit => exc
          raise exc if fail_fast == "true"
        end
      end

      # generate a report index page to tmp/code_quality/quality_audit/index.html
      if options[:generate_index] == "true"
        index_path = "tmp/code_quality/quality_audit/index.html"
        @audit_tasks.each do |task_name, report|
          report[:report_path].sub!("quality_audit/", "")
        end
        generate_index index_path
        puts "Generate report index to #{index_path}"
      end

      audit_faild "" if exc
    end

    # desc "prepare dir"
    task :prepare => :helpers do
      @report_dir = "tmp/code_quality/quality_audit"
      prepare_dir @report_dir

      def report_dir
        @report_dir
      end
    end

    desc "rubycritic"
    # e.g.: rake code_quality:quality_audit:rubycritic lowest_score=94.5
    task :rubycritic => :prepare do |task|
      options = options_from_env(:lowest_score)
      run_audit task, "Rubycritic - static analysis gems such as Reek, Flay and Flog to provide a quality report of your Ruby code." do
        report = `rubycritic -p #{report_dir}/rubycritic app lib --no-browser`
        puts report
        @report_path = report_path = "#{report_dir}/rubycritic/overview.html"
        show_in_browser File.realpath(report_path)

        # if config lowest_score then audit it with report score
        if options[:lowest_score]
          if report[-20..-1] =~ /Score: (.+)/
            report_score = $1.to_f
            lowest_score = options[:lowest_score].to_f
            audit_faild "Report score #{colorize(report_score, :yellow)} is lower then #{colorize(lowest_score, :yellow)}, must improve your code quality or set a higher #{colorize("lowest_score", :black, :white)}" if report_score < lowest_score
          end
        end
      end
    end

    desc "rubocop - audit coding style"
    # e.g.: rake code_quality:quality_audit:rubocop max_offenses=100
    # options:
    #   config_formula: use which formula for config, supports "github, "rails" or path_to_your_local_config.yml, default is "github"
    #   cli_options: pass extract options, e.g.: cli_options="--show-cops"
    #   max_offenses: if config max_offenses then audit it with detected offenses number in report, e.g.: max_offenses=100
    task :rubocop => :prepare do |task|
      run_audit task, "rubocop - RuboCop is a Ruby static code analyzer. Out of the box it will enforce many of the guidelines outlined in the community Ruby Style Guide." do
        options = options_from_env(:config_formula, :cli_options, :max_offenses)

        config_formulas = {
          'github' => 'https://github.com/github/rubocop-github',
          'rails' => 'https://github.com/rails/rails/blob/master/.rubocop.yml'
        }

        # prepare cli options
        config_formula = options.fetch(:config_formula, 'github')
        if config_formula && File.exists?(config_formula)
          config_file = config_formula
          puts "Using config file: #{config_file}"
        else
          gem_config_dir = File.expand_path("../../../config", __FILE__)
          config_file    = "#{gem_config_dir}/rubocop-#{config_formula}.yml"
          puts "Using config formula: [#{config_formula}](#{config_formulas[config_formula]})"
        end
        @report_path = report_path = "#{report_dir}/rubocop-report.html"

        # generate report
        report = `rubocop -c #{config_file} -S -R -P #{options[:cli_options]} --format offenses --format html -o #{report_path}`
        puts report
        puts "Report generated to #{report_path}"
        show_in_browser File.realpath(report_path)

        # if config max_offenses then audit it with detected offenses number in report
        if options[:max_offenses]
          if report[-20..-1] =~ /(\d+) *Total/
            detected_offenses = $1.to_i
            max_offenses = options[:max_offenses].to_i
            audit_faild "Detected offenses #{colorize(detected_offenses, :yellow)} is more then #{colorize(max_offenses, :yellow)}, must improve your code quality or set a lower #{colorize("max_offenses", :black, :white)}" if detected_offenses > max_offenses
          end
        end
      end
    end

    desc "metric_fu - many kinds of metrics"
    # e.g.: rake code_quality:quality_audit:metric_fu metrics=stats,rails_best_practices,roodi rails_best_practices_max_offenses=9 roodi_max_offenses=10
    # options:
    #   metrics: default to run all metrics, can be config as: cane,churn,flay,flog,hotspots,rails_best_practices,rcov,reek,roodi,saikuro,stats
    #   flay_max_offenses: offenses number for audit
    #   cane_max_offenses: offenses number for audit
    #   rails_best_practices_max_offenses: offenses number for audit
    #   reek_max_offenses: offenses number for audit
    #   roodi_max_offenses: offenses number for audit
    task :metric_fu => :prepare do |task|
      metrics_offenses_patterns = {
        "flay" => /Total Score (\d+)/,
        "cane" => /Total Violations (\d+)/,
        "rails_best_practices" => /Found (\d+) errors/,
        "reek" => /Found (\d+) code smells/,
        "roodi" => /Found (\d+) errors/,
      }
      metrics_have_offenses = metrics_offenses_patterns.keys.map { |metric| "#{metric}_max_offenses".to_sym }
      options = options_from_env(:metrics, *metrics_have_offenses)
      run_audit task, "metric_fu - Code metrics from Flog, Flay, Saikuro, Churn, Reek, Roodi, Code Statistics, and Rails Best Practices. (and optionally RCov)" do
        report_path = "#{report_dir}/metric_fu"
        available_metrics = %w{cane churn flay flog hotspots rails_best_practices rcov reek roodi saikuro stats}
        metric_fu_opts = ""
        selected_metrics = available_metrics
        if options[:metrics]
          selected_metrics = options[:metrics].split(",")
          disable_metrics = available_metrics - selected_metrics
          selected_metrics_opt = selected_metrics.map { |m| "--#{m}" }.join(" ")
          disable_metrics_opt = disable_metrics.map { |m| "--no-#{m}" }.join(" ")
          metric_fu_opts = "#{selected_metrics_opt} #{disable_metrics_opt}"
          puts "for metrics: #{selected_metrics.join(",")}"
        end
        # geneate report
        report = `metric_fu --no-open #{metric_fu_opts}`
        FileUtils.remove_dir(report_path) if Dir.exists? report_path
        FileUtils.mv("tmp/metric_fu/output", report_path, force: true)
        puts report
        puts "Report generated to #{report_path}"
        show_in_browser File.realpath(report_path)
        @report_path = "#{report_path}/index.html"

        # audit report result
        report_result_path = "tmp/metric_fu/report.yml"
        if File.exists? report_result_path
          require 'yaml'
          report_result = YAML.load_file(report_result_path)
          # if config #{metric}_max_offenses then audit it with report result
          audit_failures = []
          metrics_offenses_patterns.each do |metric, pattern|
            option_key = "#{metric}_max_offenses".to_sym
            if options[option_key]
              detected_offenses = report_result[metric.to_sym][:total].to_s.match(pattern)[1].to_i rescue 0
              max_offenses = options[option_key].to_i
              if detected_offenses > max_offenses
                puts "Metric #{colorize(metric, :green)} detected offenses #{colorize(detected_offenses, :yellow)} is more then #{colorize(max_offenses, :yellow)}, must improve your code quality or set a lower #{colorize(option_key, :black, :white)}"
                audit_failures << {metric: metric, detected_offenses: detected_offenses, max_offenses: max_offenses}
              end
            end
          end
          audit_faild "#{audit_failures.size} of #{selected_metrics.size} metrics audit failed" if audit_failures.any?
        end
      end
    end

    # desc "resources url"
    task :resources do
      refs = %w{
        http://awesome-ruby.com/#-code-analysis-and-metrics
        https://github.com/whitesmith/rubycritic
        https://github.com/bbatsov/rubocop
        https://github.com/bbatsov/ruby-style-guide
        https://github.com/github/rubocop-github
        https://github.com/metricfu/metric_fu
        https://rails-bestpractices.com
      }
      puts "## Code Quality Resources"
      puts refs.map { |url| "  - #{url}" }
    end
  end

  # desc "helper methods"
  task :helpers do
    def run_audit(task, title, &block)
      task_name = task.name.split(":").last
      @audit_tasks ||= {}
      @audit_tasks[task_name] ||= {
        report_path: "",
        failure: "",
      }
      puts "## #{title}"
      puts "", "```"
      exc = nil
      begin
        realtime(&block)
      rescue SystemExit => exc
        # audit faild
        @audit_tasks[task_name][:failure] = exc.message.gsub(/(\e\[\d+m)/, "")
      ensure
        # get @report_path set in each audit task
        @audit_tasks[task_name][:report_path] = @report_path&.sub("tmp/code_quality/", "")
      end
      puts "```", ""
      raise exc if exc
    end

    def realtime(&block)
      require 'benchmark'
      realtime = Benchmark.realtime do
        block.call
      end.round
      process_time = humanize_secs(realtime)
      puts "[ #{process_time} ]"
    end

    # p humanize_secs 60
    # => 1m
    # p humanize_secs 1234
    #=>"20m 34s"
    def humanize_secs(secs)
      [[60, :s], [60, :m], [24, :h], [1000, :d]].map{ |count, name|
        if secs > 0
          secs, n = secs.divmod(count)
          "#{n.to_i}#{name}"
        end
      }.compact.reverse.join(' ').chomp(' 0s')
    end

    def prepare_dir(dir)
      FileUtils.mkdir_p dir
    end

    def audit_faild(msg)
      flag = colorize("[AUDIT FAILED]", :red, :yellow)
      abort "#{flag} #{msg}"
    end

    # e.g.: options_from_env(:a, :b) => {:a => ..., :b => ... }
    def options_from_env(*keys)
      # ENV.to_h.slice(*keys.map(&:to_s)).symbolize_keys! # using ActiveSupport
      ENV.to_h.inject({}) { |opts, (k, v)| keys.include?(k.to_sym) ? opts.merge({k.to_sym => v}) : opts }
    end

    # set text color, background color using ANSI escape sequences, e.g.:
    #   colors = %w(black red green yellow blue pink cyan white default)
    #   colors.each { |color| puts colorize(color, color) }
    #   colors.each { |color| puts colorize(color, :green, color) }
    def colorize(text, color = "default", bg = "default")
      colors = %w(black red green yellow blue pink cyan white default)
      fgcode = 30; bgcode = 40
      tpl = "\e[%{code}m%{text}\e[0m"
      cov = lambda { |txt, col, cod| tpl % {text: txt, code: (cod+colors.index(col.to_s))} }
      ansi = cov.call(text, color, fgcode)
      ansi = cov.call(ansi, bg, bgcode) if bg.to_s != "default"
      ansi
    end

    def show_in_browser(dir)
      require "launchy"
      require "uri"
      uri = URI.escape("file://#{dir}/")
      if File.directory?(dir)
        uri = URI.join(uri, "index.html")
      end
      Launchy.open(uri) if open_in_browser?
    end

    def open_in_browser?
      ENV["CI"].nil?
    end

    def generate_index(index_path)
      require "erb"
      prepare_dir "tmp/code_quality"
      gem_app_dir = File.expand_path("../../../app", __FILE__)
      erb_file = "#{gem_app_dir}/views/code_quality/index.html.erb"

      # render view
      @audit_tasks ||= []
      erb = ERB.new(File.read(erb_file))
      output = erb.result(binding)

      File.open(index_path, 'w') {|f| f.write output }
    end
  end

end
