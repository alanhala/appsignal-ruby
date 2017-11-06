module Appsignal
  class Hooks
    # @api private
    class SidekiqPlugin
      include Appsignal::Hooks::Helpers

      # TODO: Make constant
      def job_keys
        @job_keys ||= Set.new(%w(
          class args retried_at failed_at
          error_message error_class backtrace
          error_backtrace enqueued_at retry
          jid retry created_at wrapped
        ))
      end

      def call(_worker, item, _queue)
        action_name = formatted_action_name(item)
        params = filtered_arguments(item)

        transaction = Appsignal::Transaction.create(
          SecureRandom.uuid,
          Appsignal::Transaction::BACKGROUND_JOB,
          Appsignal::Transaction::GenericRequest.new(
            :queue_start => item["enqueued_at"]
          )
        )

        Appsignal.instrument "perform_job.sidekiq" do
          begin
            yield
          rescue Exception => exception # rubocop:disable Lint/RescueException
            transaction.set_error(exception)
            raise exception
          end
        end
      ensure
        if transaction
          transaction.set_action_if_nil(action_name)
          transaction.params = params
          formatted_metadata(item).each do |key, value|
            transaction.set_metadata key, value
          end
          transaction.set_http_or_background_queue_start
          Appsignal::Transaction.complete_current!
        end
      end

      private

      def formatted_action_name(job)
        sidekiq_action_name = parse_action_name(job)
        return sidekiq_action_name if sidekiq_action_name =~ /\.|#/
        "#{sidekiq_action_name}#perform"
      end

      # Based on: https://github.com/mperham/sidekiq/blob/63ee43353bd3b753beb0233f64865e658abeb1c3/lib/sidekiq/api.rb#L316-L334
      def parse_action_name(job)
        case job["class"]
        when /\ASidekiq::Extensions::Delayed/
          safe_load(job["args"][0], job["class"]) do |target, method, _|
            "#{target}.#{method}"
          end
        when "ActiveJob::QueueAdapters::SidekiqAdapter::JobWrapper"
          job_class = job["wrapped"] || args[0]
          if "ActionMailer::DeliveryJob" == job_class
            # MailerClass#mailer_method
            args[0]["arguments"][0..1].join("#")
          else
            job_class
          end
        else
          job["class"]
        end
      end

      def filtered_arguments(job)
        Appsignal::Utils::ParamsSanitizer.sanitize(
          parse_arguments(job),
          :filter_parameters => Appsignal.config[:filter_parameters]
        )
      end

      # Based on: https://github.com/mperham/sidekiq/blob/63ee43353bd3b753beb0233f64865e658abeb1c3/lib/sidekiq/api.rb#L336-L358
      def parse_arguments(job)
        args = job["args"]
        case job["class"]
        when /\ASidekiq::Extensions::Delayed/
          safe_load(args[0], args) do |_, _, arg|
            arg
          end
        when "ActiveJob::QueueAdapters::SidekiqAdapter::JobWrapper"
          is_wrapped = job["wrapped"]
          job_args = is_wrapped ? job["args"][0]["arguments"] : []
          if "ActionMailer::DeliveryJob" == (is_wrapped || args[0])
            # Remove MailerClass, mailer_method and "deliver_now"
            job_args.drop(3)
          else
            job_args
          end
        else
          # TODO: Keep?
          # if self["encrypt".freeze]
          #   # no point in showing 150+ bytes of random garbage
          #   args[-1] = "[encrypted data]".freeze
          # end
          args
        end
      end

      # Source: https://github.com/mperham/sidekiq/blob/63ee43353bd3b753beb0233f64865e658abeb1c3/lib/sidekiq/api.rb#L403-L412
      def safe_load(content, default)
        yield(*YAML.load(content))
      rescue => error
        # Sidekiq issue #1761: in dev mode, it's possible to have jobs enqueued
        # which haven't been loaded into memory yet so the YAML can't be
        # loaded.
        Appsignal.logger.warn "Unable to load YAML: #{error.message}"
        default
      end

      def formatted_metadata(item)
        {}.tap do |hash|
          (item || {}).each do |key, value|
            next if job_keys.include?(key)
            hash[key] = truncate(string_or_inspect(value))
          end
        end
      end
    end

    class SidekiqHook < Appsignal::Hooks::Hook
      register :sidekiq

      def dependencies_present?
        defined?(::Sidekiq)
      end

      def install
        ::Sidekiq.configure_server do |config|
          config.server_middleware do |chain|
            chain.add Appsignal::Hooks::SidekiqPlugin
          end
        end
      end
    end
  end
end
