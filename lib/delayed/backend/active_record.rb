require 'active_record/version'
module Delayed
  module Backend
    module ActiveRecord
      # A job object that is persisted to the database.
      # Contains the work object as a YAML field.
      class Job < ::ActiveRecord::Base
        include Delayed::Backend::Base

        attr_accessible :priority, :run_at, :queue, :payload_object,
          :failed_at, :locked_at, :locked_by

        before_save :set_default_run_at

        def self.rails3?
          ::ActiveRecord::VERSION::MAJOR == 3
        end

        delayed_job_table_name = "#{::ActiveRecord::Base.table_name_prefix}delayed_jobs"

        if rails3?
          self.table_name = delayed_job_table_name
          def self.ready_to_run(worker_name, max_run_time, limit)
            locked_is_null =    select(:id).where('run_at <= ? AND locked_at is NULL AND failed_at is NULL', db_time_now).order('priority ASC, run_at ASC').limit(limit)
            locked_at_db_time = select(:id).where('run_at <= ? AND locked_at < ?     AND failed_at is NULL', db_time_now, db_time_now - max_run_time).order('priority ASC, run_at ASC').limit(limit)
            locked_by_worker  = select(:id).where('run_at <= ? AND locked_by = ?     AND failed_at is NULL', db_time_now, worker_name).order('priority ASC, run_at ASC').limit(limit)
            probable_ids = (locked_is_null.to_a + locked_at_db_time.to_a + locked_by_worker.to_a).flatten.map(&:id)
            if probable_ids.length > 0
              where('id in (?) AND run_at <= ? AND (locked_at IS NULL OR locked_at < ? OR locked_by = ?) AND failed_at IS NULL', probable_ids, db_time_now, db_time_now - max_run_time, worker_name)
            else
              where('run_at <= ? AND (locked_at IS NULL OR locked_at < ? OR locked_by = ?) AND failed_at IS NULL', db_time_now, db_time_now - max_run_time, worker_name)
            end
          end
          def self.by_priority
            order('priority ASC, run_at ASC')
          end
        else
          set_table_name delayed_job_table_name
          named_scope :ready_to_run, lambda {|worker_name, max_run_time, limit|
            { :conditions => ['(run_at <= ? AND (locked_at IS NULL OR locked_at < ?) OR locked_by = ?) AND failed_at IS NULL', db_time_now, db_time_now - max_run_time, worker_name] }
          }
          named_scope :by_priority, :order => 'priority ASC, run_at ASC'
        end

        def self.before_fork
          ::ActiveRecord::Base.clear_all_connections!
        end

        def self.after_fork
          ::ActiveRecord::Base.establish_connection
        end

        # When a worker is exiting, make sure we don't have any locked jobs.
        def self.clear_locks!(worker_name)
          update_all("locked_by = null, locked_at = null", ["locked_by = ?", worker_name])
        end

        # Find a few candidate jobs to run (in case some immediately get locked by others).
        def self.find_available(worker_name, limit = 5, max_run_time = Worker.max_run_time)
          scope = self.ready_to_run(worker_name, max_run_time, limit)
          scope = scope.scoped(:conditions => ['priority >= ?', Worker.min_priority]) if Worker.min_priority
          scope = scope.scoped(:conditions => ['priority <= ?', Worker.max_priority]) if Worker.max_priority
          scope = scope.scoped(:conditions => ["queue IN (?)", Worker.queues]) if Worker.queues.any?

          ::ActiveRecord::Base.silence do
            scope.by_priority.all(:limit => limit)
          end
        end

        # Lock this job for this worker.
        # Returns true if we have the lock, false otherwise.
        def lock_exclusively!(max_run_time, worker)
          now = self.class.db_time_now
          affected_rows = if locked_by != worker
            # We don't own this job so we will update the locked_by name and the locked_at
            self.class.update_all(["locked_at = ?, locked_by = ?", now, worker], ["id = ? and (locked_at is null or locked_at < ?) and (run_at <= ?)", id, (now - max_run_time.to_i), now])
          else
            # We already own this job, this may happen if the job queue crashes.
            # Simply resume and update the locked_at
            self.class.update_all(["locked_at = ?", now], ["id = ? and locked_by = ?", id, worker])
          end
          if affected_rows == 1
            self.locked_at = now
            self.locked_by = worker
            self.locked_at_will_change!
            self.locked_by_will_change!
            return true
          else
            return false
          end
        end

        # Get the current time (GMT or local depending on DB)
        # Note: This does not ping the DB to get the time, so all your clients
        # must have syncronized clocks.
        def self.db_time_now
          if Time.zone
            Time.zone.now
          elsif ::ActiveRecord::Base.default_timezone == :utc
            Time.now.utc
          else
            Time.now
          end
        end

        def reload(*args)
          reset
          super
        end
      end
    end
  end
end
