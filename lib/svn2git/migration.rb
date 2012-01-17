require 'optparse'
require 'pp'

module Svn2Git
  DEFAULT_AUTHORS_FILE = "~/.svn2git/authors"

  class Migration

    attr_reader :dir

    def initialize(args)
      @options = parse(args)
      if @options[:rebase]
         show_help_message('Too many arguments') if args.size > 0
         if !@options[:bare]
            verify_working_tree_is_clean
         end
      else
         show_help_message('Missing SVN_URL parameter') if args.empty? && @options[:clone]
         show_help_message('Too many arguments') if args.size > 1
         @url = args.first
      end
    end

    def run!
      if @options[:rebase] || !@options[:clone]
        get_branches
      else
        clone!
      end
      fix_tags
      fix_branches
      optimize_repos
    end

    def parse(args)
      # Set up reasonable defaults for options.
      options = {}
      options[:verbose] = false
      options[:metadata] = false
      options[:nominimizeurl] = false
      options[:rootistrunk] = false
      options[:trunk] = 'trunk'
      options[:branches] = 'branches'
      options[:tags] = 'tags'
      options[:exclude] = []
      options[:revision] = nil
      options[:username] = nil
      options[:clone] = true
      options[:bare] = false
      options[:repository] = '';

      if File.exists?(File.expand_path(DEFAULT_AUTHORS_FILE))
        options[:authors] = DEFAULT_AUTHORS_FILE
      end


      # Parse the command-line arguments.
      @opts = OptionParser.new do |opts|
        opts.banner = 'Usage: svn2git SVN_URL [options]'

        opts.separator ''
        opts.separator 'Specific options:'
        
        opts.on('-r', '--repository DIRECTORY', 'The target GIT repository directory') do |repos|
          options[:repository] = repos
        end

        opts.on('--bare', 'Make a bare GIT repository') do
          options[:bare] = true
        end

        opts.on('--rebase', 'Instead of cloning a new project, rebase an existing one against SVN') do
          options[:rebase] = true
        end

        opts.on('--username NAME', 'Username for transports that needs it (http(s), svn)') do |username|
          options[:username] = username
        end

        opts.on('--trunk TRUNK_PATH', 'Subpath to trunk from repository URL (default: trunk)') do |trunk|
          options[:trunk] = trunk
        end

        opts.on('--branches BRANCHES_PATH', 'Subpath to branches from repository URL (default: branches)') do |branches|
          options[:branches] = branches
        end

        opts.on('--tags TAGS_PATH', 'Subpath to tags from repository URL (default: tags)') do |tags|
          options[:tags] = tags
        end

        opts.on('--rootistrunk', 'Use this if the root level of the repo is equivalent to the trunk and there are no tags or branches') do
          options[:rootistrunk] = true
          options[:trunk] = nil
          options[:branches] = nil
          options[:tags] = nil
        end

        opts.on('--notrunk', 'Do not import anything from trunk') do
          options[:trunk] = nil
        end

        opts.on('--nobranches', 'Do not try to import any branches') do
          options[:branches] = nil
        end

        opts.on('--notags', 'Do not try to import any tags') do
          options[:tags] = nil
        end

        opts.on('--no-minimize-url', 'Accept URLs as-is without attempting to connect to a higher level directory') do
          options[:nominimizeurl] = true
        end

        opts.on('--revision REV', 'Start importing from SVN revision') do |revision|
          options[:revision] = revision
        end

        opts.on('-m', '--metadata', 'Include metadata in git logs (git-svn-id)') do
          options[:metadata] = true
        end

        opts.on('--authors AUTHORS_FILE', "Path to file containing svn-to-git authors mapping (default: #{DEFAULT_AUTHORS_FILE})") do |authors|
          options[:authors] = authors
        end

        opts.on('--exclude REGEX', 'Specify a Perl regular expression to filter paths when fetching; can be used multiple times') do |regex|
          options[:exclude] << regex
        end

        opts.on('-v', '--verbose', 'Be verbose in logging -- useful for debugging issues') do
          options[:verbose] = true
        end
        
        opts.on('--no-clone', 'Do not clone from svn, just fix up the current repo') do
          options[:clone] = false
        end

        opts.separator ""

        # No argument, shows at tail.  This will print an options summary.
        # Try it and see!
        opts.on_tail('-h', '--help', 'Show this message') do
          puts opts
          exit
        end
      end

      @opts.parse! args
      options
    end

    private

    def clone!
      trunk = @options[:trunk]
      branches = @options[:branches]
      tags = @options[:tags]
      metadata = @options[:metadata]
      nominimizeurl = @options[:nominimizeurl]
      rootistrunk = @options[:rootistrunk]
      authors = @options[:authors]
      exclude = @options[:exclude]
      revision = @options[:revision]
      username = @options[:username]
      repos = @options[:repository] 

      cmd = "git "
      if @options[:bare]
        _cmd = 'git --bare init '
        _cmd +=  repos unless repos == ''
        run_command(_cmd)
        cmd += "--bare "
        cmd += "--git-dir='#{repos}' "
      end
      if rootistrunk
        # Non-standard repository layout.  The repository root is effectively 'trunk.'
        cmd += "svn init --prefix=svn/ "
        cmd += "--username=#{username} " unless username.nil?
        cmd += "--no-metadata " unless metadata
        if nominimizeurl
          cmd += "--no-minimize-url "
        end
        cmd += "--trunk=#{@url}"
        run_command(cmd)

      else
        cmd += "svn init --prefix=svn/ "

        # Add each component to the command that was passed as an argument.
        cmd += "--username=#{username} " unless username.nil?
        cmd += "--no-metadata " unless metadata
        if nominimizeurl
          cmd += "--no-minimize-url "
        end
        cmd += "--trunk=#{trunk} " unless trunk.nil?
        cmd += "--tags=#{tags} " unless tags.nil?
        cmd += "--branches=#{branches} " unless branches.nil?

        cmd += @url

        run_command(cmd)
      end

      if not authors.nil?
        cmd = "git "
        cmd += "--git-dir='#{repos}' " unless repos == ''
        cmd += "config --local svn.authorsfile #{authors}"
        run_command(cmd)
      end

      cmd = "git "
      cmd += "--git-dir='#{repos}' " unless repos == ''
      cmd += 'svn fetch '
      cmd += "-r #{revision}:HEAD " unless revision.nil?
      unless exclude.empty?
        # Add exclude paths to the command line; some versions of git support
        # this for fetch only, later also for init.
        regex = []
        unless rootistrunk
          regex << "#{trunk}[/]" unless trunk.nil?
          regex << "#{tags}[/][^/]+[/]" unless tags.nil?
          regex << "#{branches}[/][^/]+[/]" unless branches.nil?
        end
        regex = '^(?:' + regex.join('|') + ')(?:' + exclude.join('|') + ')'
        cmd += "'--ignore-paths=#{regex}'"
      end
      run_command(cmd)

      get_branches
    end

    def get_branches
      repos = @options[:repository]
      # Get the list of local and remote branches, taking care to ignore console color codes and ignoring the
      # '*' character used to indicate the currently selected branch.}
      cmd = 'git '
      cmd += "--git-dir='#{repos}' " unless repos == ''

      if @options[:rebase]
         run_command("#{cmd} svn fetch")
      end

      @local = run_command("#{cmd} branch -l --no-color").split(/\n/).collect{ |b| b.gsub(/\*/,'').strip }
      @remote = run_command("#{cmd} branch -r --no-color").split(/\n/).collect{ |b| b.gsub(/\*/,'').strip }

      # Tags are remote branches that start with "tags/".
      @tags = @remote.find_all { |b| b.strip =~ %r{^svn\/tags\/} }
    end

    def fix_tags
      current = {}
      current['user.name']  = run_command("git config --local --get user.name")
      current['user.email'] = run_command("git config --local --get user.email")

      repos = @options[:repository]
 
      _cmd = 'git '
      _cmd += "--git-dir='#{repos}' " unless repos == ''
      @tags.each do |tag|
        tag = tag.strip
        id      = tag.gsub(%r{^svn\/tags\/}, '').strip
        subject = run_command("#{_cmd} log -1 --pretty=format:'%s' '#{escape_quotes(tag)}'")
        date    = run_command("#{_cmd} log -1 --pretty=format:'%ci' '#{escape_quotes(tag)}'")
        author  = run_command("#{_cmd} log -1 --pretty=format:'%an' '#{escape_quotes(tag)}'")
        email   = run_command("#{_cmd} log -1 --pretty=format:'%ae' '#{escape_quotes(tag)}'")
        run_command("#{_cmd} config --local user.name '#{escape_quotes(author)}'")
        run_command("#{_cmd} config --local user.email '#{escape_quotes(email)}'")
        run_command("GIT_COMMITTER_DATE='#{escape_quotes(date)}' #{_cmd} tag -a -m '#{escape_quotes(subject)}' '#{escape_quotes(id)}' '#{escape_quotes(tag)}'")
        run_command("#{_cmd} branch -d -r '#{escape_quotes(tag)}'")
      end

    ensure
      current.each_pair do |name, value|
        # If a line was read, then there was a config value so restore it.
        # Otherwise unset the value because originally there was none.
        if value[-1] == "\n"
          run_command("git config --local #{name} '#{value.chomp("\n")}'")
        else
          run_command("git config --local --unset #{name}")
        end
      end
    end

    def fix_branches
      repos = @options[:repository]
 
      _cmd = 'git '
      svn_branches = @remote - @tags
      svn_branches.delete_if { |b| b.strip !~ %r{^svn\/} }

      _repos = repos
      if @options[:bare] && @options[:rebase]
        __cmd = 'git clone -l '
        if repos == ''
          __cmd += ' . ./tmp'
        else
          __cmd += ' #{repos} #{repos}/tmp'
        end
        run_command("#{__cmd}")
        _repos += "/tmp/"
      end
      _cmd += "--git-dir='#{repos}' " unless repos == ''

      svn_branches.each do |branch|
        branch = branch.gsub(/^svn\//,'').strip
        if @options[:rebase] && (@local.include?(branch) || branch == 'trunk')
          lbranch = branch
          lbranch = 'master' if branch == 'trunk'
          if @options[:bare] && _repos != ''
            run_command("#{_cmd} branch \"new#{branch}\" \"remotes/svn/#{branch}\"")
            run_command("#{__cmd}")
            run_command("pushd #{_repos}")
            run_command("git branch \"new#{branch}\" \"remotes/origin/new#{branch}\"")
            run_command("git checkout -f \"#{lbranch}\"")
            run_command("git rebase \"new#{branch}\"")
            run_command("git push")
            run_command("popd")
            run_command("rm -rf #{_repos}"))
            run_command("#{_cmd} branch -d \"new#{branch}\"")
          else
            run_command("#{_cmd} checkout -f \"#{lbranch}\"")
            run_command("#{_cmd} rebase \"remotes/svn/#{branch}\"")
          end
          next
        end

        next if @local.include?(branch)
        run_command("#{_cmd} branch \"#{branch}\" \"remotes/svn/#{branch}\"")
        run_command("#{_cmd} branch -d -r \"svn/#{branch}\"")
      end
      run_command("#{_cmd} push")
    end

    def optimize_repos
      repos = @options[:repository]
 
      _cmd = 'git '
      _cmd += "--git-dir='#{repos}' " unless repos == ''

      run_command("#{_cmd} gc")
    end

    def run_command(cmd)
      log "Running command: #{cmd}"

      ret = ''

      cmd = "2>&1 #{cmd}"
      IO.popen(cmd) do |stdout|
        stdout.each do |line|
          log line
          ret << line
        end
      end

      unless $?.success?
        $stderr.puts "command failed (#{$?.exitstatus}):\n#{cmd}"
        exit 1
      end

      ret
    end

    def log(msg)
      puts msg if @options[:verbose]
    end

    def show_help_message(msg)
      puts "Error starting script: #{msg}\n\n"
      puts @opts.help
      exit
    end

    def verify_working_tree_is_clean
      repos = @options[:repository]
 
      _cmd = 'git '
      _cmd += "--git-dir='#{repos}' " unless repos == ''

      status = run_command("#{_cmd} status --porcelain --untracked-files=no")
      unless status.strip == ''
        puts 'You have local pending changes.  The working tree must be clean in order to continue.'
        exit (-1)
      end
    end

    def escape_quotes(str)
      str.gsub("'", "'\\\\''")
    end

  end
end

if $0 == __FILE__ then
  migration = Svn2Git::Migration.new(ARGV)
  migration.run!
end