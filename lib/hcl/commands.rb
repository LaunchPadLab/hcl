require 'chronic'
require 'highline'

module HCl
  module Commands
    class Error < StandardError; end

    # Display a sanitized view of your auth credentials.
    def config
      http.config_hash.merge(password: '***')
          .map { |k, v| "#{k}: #{v}" }.join("\n")
    end

    # Show the network status of the Harvest service.
    def status
      result = Faraday.new('http://kccljmymlslr.statuspage.io/api/v2') do |f|
        f.adapter Faraday.default_adapter
      end.get('status.json').body

      json = Yajl::Parser.parse result, symbolize_keys: true
      status = json[:status][:description]
      updated_at = DateTime.parse(json[:page][:updated_at]).strftime '%F %T %:z'

      "#{status} [#{updated_at}]"
    end

    def console
      Console.new(self)
      nil
    end

    def tasks(options, project_code = nil)
      tasks = Task.all
      if tasks.empty? || options[:clearcache] # cache tasks
        DayEntry.today(http)
        tasks = Task.all
      end
      tasks.select! { |t| t.project.code == project_code } if project_code
      raise 'No matching tasks.' if tasks.empty?
      tasks.map { |task| "#{task.project.id} #{task.id}\t#{task}" }.join("\n")
    end

    def set(key = nil, *args)
      if key.nil?
        @settings.each do |k, v|
          puts "#{k}: #{v}"
        end
      else
        value = args.join(' ')
        @settings ||= {}
        @settings[key] = value
        write_settings
      end
      nil
    end

    def cancel
      entry = DayEntry.with_timer(http) || DayEntry.last(http)
      raise 'Nothing to cancel.' unless entry
      confirmed = /^y/.match(ask("#{entry}\nDelete this entry? (y/n): ").downcase)
      return unless confirmed
      raise "Failed to delete #{entry}!" unless entry.cancel http
      "Deleted entry #{entry}."        
    end
    alias_method :oops, :cancel
    alias_method :nvm, :cancel

    def unset(key)
      @settings.delete key
      write_settings
    end

    def unalias(task)
      unset "task.#{task}"
      "Removed task alias @#{task}."
    end

    def alias(task_name, *value)
      task = Task.find(*value)
      raise "Unrecognized project and task ID: #{value.inspect}" unless task
      set "task.#{task_name}", *value
      "Added alias @#{task_name} for #{task}."
    end

    def completion(command = nil)
      command ||= $PROGRAM_NAME.split('/').last
      $stderr.puts \
        'The hcl completion command is deprecated (and slow!), instead use something like:',
        "> complete -W \"`cat #{HCl::App::ALIAS_LIST}`\" #{command}"
      %[complete -W "#{aliases.join ' '}" #{command}]
    end

    def aliases
      @settings.keys.select { |s| s =~ /^task\./ }.map { |s| '@' + s.slice(5..-1) }
    end

    def start(*args)
      starting_time = get_starting_time args
      task = get_task args
      if task.nil?
        raise 'Unknown task alias, try one of the following: ', aliases.join(', ')
      end
      timer = task.start http,
        :starting_time => starting_time,
        :note => args.join(' ')
      "Started timer for #{timer} (at #{current_time})"
    end

    def log(*args)
      raise 'There is already a timer running.' if DayEntry.with_timer(http)
      start(*args)
      stop
    end

    def stop(*args)
      entry = DayEntry.with_timer(http) || DayEntry.with_timer(http, Date.today - 1)
      raise 'No running timers found.' unless entry
      entry.append_note(http, args.join(' ')) if args.any?
      entry.toggle http
      "Stopped #{entry} (at #{current_time})"
    end

    def note(*args)
      entry = DayEntry.with_timer http
      raise 'No running timers found.' unless entry
      return entry.notes if args.empty?
      entry.append_note http, args.join(' ')
      "Added note to #{entry}."
    end

    def show(*args)
      date = args.empty? ? nil : Chronic.parse(args.join(' '))
      total_hours = 0.0
      result = ''
      DayEntry.daily(http, date).each do |day|
        running = day.running? ? '(running) ' : ''
        columns = HighLine::SystemExtensions.terminal_size[0] rescue 80
        result << "\t#{day.formatted_hours}\t#{running}#{day.project}: #{day.notes.lines.to_a.last}\n"[0..columns - 1]
        total_hours += day.hours.to_f
      end
      result << ("\t" + '-' * 13) << "\n"
      result << "\t#{as_hours total_hours}\ttotal (as of #{current_time})\n"
    end

    def resume(*args)
      ident = get_ident args
      entry = if ident
                task_ids = get_task_ids ident, args
                DayEntry.last_by_task http, *task_ids
              else
                DayEntry.last(http)
              end
      raise 'No matching timer found.' unless entry
      entry.toggle http
    end
  end
end
