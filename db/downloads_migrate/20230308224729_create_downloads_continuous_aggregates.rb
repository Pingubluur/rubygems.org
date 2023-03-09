class CreateDownloadsContinuousAggregates < ActiveRecord::Migration[7.0]
  disable_ddl_transaction!

  def execute(...)
    puts(...)
    super
  end

  def create_continuous_aggregate(name, ...)
    execute "DROP MATERIALIZED VIEW IF EXISTS #{connection.quote_table_name(name)} CASCADE;"
    super
  rescue ActiveRecord::StatementInvalid => e
    raise unless e.cause.is_a?(PG::DatetimeFieldOverflow)
    say "WARNING: #{e}"
    nil
  end

  def continuous_aggregate(
    duration:,
    from: Download.table_name,
    start_offset:,
    end_offset:,
    schedule_window:,
    retention: start_offset
  )
    name = "downloads_" + duration.inspect.parameterize(separator: '_')
    start_offset ||= 20.years

    create_continuous_aggregate(
      name,
      Download.
        time_bucket(duration.iso8601, select_alias: :occurred_at).
        group(:rubygem_id, :version_id).
        select(:rubygem_id, :version_id).
        sum(:downloads, :downloads).
        reorder(nil).
        from(from).
        to_sql
    )
    add_continuous_aggregate_policy(name, start_offset&.iso8601, end_offset&.iso8601, schedule_window)
    add_hypertable_retention_policy(name, retention.iso8601) if retention

    all_versions_name = name + "_all_versions"
    create_continuous_aggregate(
      all_versions_name,
      Download.
        time_bucket(duration.iso8601, select_alias: :occurred_at).
        group(:rubygem_id).
        select(:rubygem_id).
        sum(:downloads, :downloads).
        from(name).
        to_sql
    )
    add_continuous_aggregate_policy(all_versions_name, start_offset&.iso8601, end_offset&.iso8601, schedule_window)
    add_hypertable_retention_policy(all_versions_name, retention.iso8601) if retention

    all_gems_name = name + "_all_gems"
    create_continuous_aggregate(
      all_gems_name,
      Download.
        time_bucket(duration.iso8601, select_alias: :occurred_at).
        sum(:downloads, :downloads).
        from(all_versions_name).
        to_sql
    )
    add_continuous_aggregate_policy(all_gems_name, start_offset&.iso8601, end_offset&.iso8601, schedule_window)
    add_hypertable_retention_policy(all_gems_name, retention.iso8601) if retention

    name
  end

  def change
    ActiveRecord::Base.logger = Logger.new(STDERR)
    from = continuous_aggregate(
      duration: 15.minutes,
      start_offset: 1.week,
      end_offset: 1.hour,
      schedule_window: 1.hour
    )

    from = continuous_aggregate(
      duration: 1.day,
      start_offset: 2.years,
      end_offset: 1.day,
      schedule_window: 12.hours,
      from:
    )

    from = continuous_aggregate(
      duration: 1.month,
      start_offset: nil,
      end_offset: 1.month,
      schedule_window: 1.day,
      retention: nil,
      from:
    )

    from = continuous_aggregate(
      duration: 1.year,
      start_offset: nil,
      end_offset: 1.year,
      schedule_window: 1.month,
      retention: nil,
      from:
    )
  end
end
