class Download < DownloadRecord
  belongs_to :rubygem
  belongs_to :version

  def self.suffix = nil
  def self.time_period = nil

  def self.class_name_for(suffix:, time_period:)
    raise ArgumentError if suffix && !time_period
    "#{time_period.iso8601}#{"_#{suffix}" if suffix}".classify
  end

  [15.minutes, 1.day, 1.month, 1.year].each do |time_period|
    (%w[all_versions all_gems] << nil).each do |suffix|
      table_name = "#{Download.table_name}_#{time_period.inspect.parameterize(separator: '_')}#{"_#{suffix}" if suffix}"
      ::Download.class_eval(<<~RUBY, __FILE__, __LINE__ + 1) # rubocop:disable Style/DocumentDynamicEvalDefinition
        class #{class_name_for(suffix:, time_period:)} < Download
          attribute :downloads, :integer

          def readonly?
            true
          end

          def self.table_name = #{table_name.dump}

          def self.suffix = #{suffix&.dump || :nil}

          def self.time_period = #{time_period.inspect.parameterize(separator: '_').dump}
        end
      RUBY
    end
  end
end
