class ExpirePushesJob < ApplicationJob
  queue_as :default

  ##
  # This job is responsible for scanning all unexpired password pushes and
  # conditionally expiring them.  This is a preemptive measure to expire pushes
  # periodically.  It saves some CPU and DB calls on live requests.
  #
  def perform(*args)
    # Log task start
    logger.info("--> #{self.class.name}: Starting...")

    counter = 0
    expiration_count = 0

    Password.where(expired: false).find_each do |push|
      counter += 1
      push.validate!
      expiration_count += 1 if push.expired
    end

    logger.info("  -> Finished validating #{counter} unexpired password pushes.  #{expiration_count} total pushes expired...")

    if Settings.enable_file_pushes
      counter = 0
      expiration_count = 0
      FilePush.where(expired: false).find_each do |push|
        counter += 1
        push.validate!
        expiration_count += 1 if push.expired
      end
      logger.info("  -> Finished validating #{counter} unexpired File pushes.  #{expiration_count} total pushes expired...")
    end

    if Settings.enable_url_pushes
      counter = 0
      expiration_count = 0
      Url.where(expired: false).find_each do |push|
        counter += 1
        push.validate!
        expiration_count += 1 if push.expired
      end
      logger.info("  -> Finished validating #{counter} unexpired URL pushes.  #{expiration_count} total pushes expired...")
    end

    # Log results
    logger.info("  -> #{self.class.name}: #{counter} anonymous and expired pushes have been deleted.")

    # Log completion
    logger.info("  -> #{self.class.name}: Finished.")
  end

  private

  def logger
    @logger ||= if ENV.key?(PWP_WORKER)
      # We are running inside the pwpush-worker container.  Log to STDOUT
      # so that docker logs works to investigate problems.
      Logger.new($stdout)
    else
      Logger.new(Rails.root.join("log", "recurring.log"))
    end
  end
end
