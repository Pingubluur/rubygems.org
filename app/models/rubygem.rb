class Rubygem < ApplicationRecord
  include Patterns
  include RubygemSearchable

  has_many :ownerships, -> { confirmed }, dependent: :destroy, inverse_of: :rubygem
  has_many :ownerships_including_unconfirmed, dependent: :destroy, class_name: "Ownership"
  has_many :owners, through: :ownerships, source: :user
  has_many :owners_including_unconfirmed, through: :ownerships_including_unconfirmed, source: :user
  has_many :push_notifiable_owners, ->(gem) { gem.owners.push_notifiable_owners }, through: :ownerships, source: :user
  has_many :ownership_notifiable_owners, ->(gem) { gem.owners.ownership_notifiable_owners }, through: :ownerships, source: :user
  has_many :ownership_request_notifiable_owners, ->(gem) { gem.owners.ownership_request_notifiable_owners }, through: :ownerships, source: :user
  has_many :subscriptions, dependent: :destroy
  has_many :subscribers, through: :subscriptions, source: :user
  has_many :versions, dependent: :destroy, validate: false
  has_one :latest_version, -> { where(latest: true).order(:position) }, class_name: "Version", inverse_of: :rubygem
  has_many :web_hooks, dependent: :destroy
  has_one :linkset, dependent: :destroy
  has_one :gem_download, -> { where(version_id: 0) }, inverse_of: :rubygem
  has_many :ownership_calls, -> { opened }, dependent: :destroy, inverse_of: :rubygem
  has_many :ownership_requests, -> { opened }, dependent: :destroy, inverse_of: :rubygem
  has_many :audits, as: :auditable, inverse_of: :auditable

  validate :ensure_name_format, if: :needs_name_validation?
  validates :name,
    length: { maximum: Gemcutter::MAX_FIELD_LENGTH },
    presence: true,
    uniqueness: { case_sensitive: false },
    if: :needs_name_validation?
  validate :reserved_names_exclusion
  validate :protected_gem_typo, on: :create, unless: -> { Array(validation_context).include?(:typo_exception) }

  after_create :update_unresolved
  # TODO: Remove this once we move to GemDownload only
  after_create :create_gem_download
  before_destroy :mark_unresolved

  MFA_RECOMMENDED_THRESHOLD = 165_000_000
  MFA_REQUIRED_THRESHOLD = 180_000_000

  scope :mfa_recommended, -> { joins(:gem_download).where("gem_downloads.count > ?", MFA_RECOMMENDED_THRESHOLD) }
  scope :mfa_required, -> { joins(:gem_download).where("gem_downloads.count > ?", MFA_REQUIRED_THRESHOLD) }

  def create_gem_download
    GemDownload.create!(count: 0, rubygem_id: id, version_id: 0)
  end

  scope :with_versions, lambda {
    where(indexed: true)
  }

  scope :without_versions, lambda {
    where(indexed: false)
  }

  scope :with_one_version, lambda {
    select("rubygems.*")
      .joins(:versions)
      .group(column_names.map { |name| "rubygems.#{name}" }.join(", "))
      .having("COUNT(versions.id) = 1")
  }

  scope :name_is, lambda { |name|
    sensitive = where(name: name.strip).limit(1)
    return sensitive unless sensitive.empty?

    where("UPPER(name) = UPPER(?)", name.strip).limit(1)
  }

  scope :name_starts_with, lambda { |letter|
    where("UPPER(name) LIKE UPPER(?)", "#{letter}%")
  }

  scope :total_count, lambda {
    with_versions.count
  }

  scope :latest, lambda { |limit = 5|
    with_one_version.order(created_at: :desc).limit(limit)
  }

  scope :downloaded, lambda { |limit = 5|
    with_versions.by_downloads.limit(limit)
  }

  scope :letter, lambda { |letter|
    name_starts_with(letter).by_name.with_versions
  }

  scope :by_name, lambda {
    order(name: :asc)
  }

  scope :by_downloads, lambda {
    joins(:gem_download).order("gem_downloads.count DESC")
  }

  scope :news, lambda { |days|
    joins(:latest_version)
      .where("versions.created_at BETWEEN ? AND ?", days.ago.in_time_zone, Time.zone.now)
      .group(:id)
      .order("MAX(versions.created_at) DESC")
  }

  scope :popular, lambda { |days|
    joins(:gem_download).order("MAX(gem_downloads.count) DESC").news(days)
  }

  def self.letterize(letter)
    /\A[A-Za-z]\z/.match?(letter) ? letter.upcase : "A"
  end

  def self.current_rubygems_release
    rubygem = find_by(name: "rubygems-update")
    rubygem && rubygem.versions.release.indexed.latest.first
  end

  def all_errors(version = nil)
    [self, linkset, version].compact.map do |ar|
      ar.errors.full_messages
    end.flatten.join(", ")
  end

  def public_versions(limit = nil)
    versions.includes(:gem_download).by_position.published(limit)
  end

  def public_versions_with_extra_version(extra_version)
    versions = public_versions(5).to_a
    versions << extra_version
    versions.uniq.sort_by(&:position)
  end

  def public_version_payload(number, platform = nil)
    version =
      if platform
        public_versions.find_by(number: number, platform: platform)
      else
        public_versions.find_by(number: number)
      end
    payload(version).merge!(version.as_json) if version
  end

  def find_version!(number:, platform:)
    platform = platform.presence || "ruby"
    versions.find_by!(number: number, platform: platform)
  end

  def find_version_by_slug!(slug)
    full_name = "#{name}-#{slug}"
    versions.find_by!(full_name: full_name)
  end

  def hosted?
    versions.count.nonzero?
  end

  def unowned?
    ownerships.blank?
  end

  def indexed_versions?
    versions.indexed.count > 0
  end

  def owned_by?(user)
    return false unless user
    ownerships.exists?(user_id: user.id)
  end

  def unconfirmed_ownerships
    ownerships_including_unconfirmed.unconfirmed
  end

  def unconfirmed_ownership?(user)
    unconfirmed_ownerships.exists?(user: user)
  end

  def to_s
    most_recent_version&.to_title || name
  end

  def downloads
    gem_download&.count || 0
  end

  def most_recent_version
    versions.most_recent
  end

  def links(version = most_recent_version)
    Links.new(self, version)
  end

  def payload(version = most_recent_version, protocol = Gemcutter::PROTOCOL, host_with_port = Gemcutter::HOST)
    versioned_links = links(version)
    deps = version.dependencies.to_a
    {
      "name"               => name,
      "downloads"          => downloads,
      "version"            => version.number,
      "version_created_at" => version.created_at,
      "version_downloads"  => version.downloads_count,
      "platform"           => version.platform,
      "authors"            => version.authors,
      "info"               => version.info,
      "licenses"           => version.licenses,
      "metadata"           => version.metadata,
      "yanked"             => version.yanked?,
      "sha"                => version.sha256_hex,
      "project_uri"        => "#{protocol}://#{host_with_port}/gems/#{name}",
      "gem_uri"            => "#{protocol}://#{host_with_port}/gems/#{version.full_name}.gem",
      "homepage_uri"       => versioned_links.homepage_uri,
      "wiki_uri"           => versioned_links.wiki_uri,
      "documentation_uri"  => versioned_links.documentation_uri,
      "mailing_list_uri"   => versioned_links.mailing_list_uri,
      "source_code_uri"    => versioned_links.source_code_uri,
      "bug_tracker_uri"    => versioned_links.bug_tracker_uri,
      "changelog_uri"      => versioned_links.changelog_uri,
      "funding_uri"        => versioned_links.funding_uri,
      "dependencies"       => {
        "development" => deps.select { |r| r.rubygem && r.scope == "development" },
        "runtime"     => deps.select { |r| r.rubygem && r.scope == "runtime" }
      }
    }
  end

  def as_json(*)
    payload
  end

  def to_xml(options = {})
    payload.to_xml(options.merge(root: "rubygem"))
  end

  def to_param
    name.remove(/[^#{Patterns::ALLOWED_CHARACTERS}]/o)
  end

  def pushable?
    new_record? || (versions.indexed.none? && not_protected?)
  end

  def create_ownership(user)
    Ownership.create_confirmed(self, user, user) if unowned?
  end

  def ownership_call
    ownership_calls.find_by(status: "opened")
  end

  def ownership_requestable?
    abandoned_release_threshold   = 1.year.ago
    abandoned_downloads_threshold = 10_000
    ownership_calls.any? || (latest_version && latest_version.created_at < abandoned_release_threshold && downloads < abandoned_downloads_threshold)
  end

  def update_versions!(version, spec)
    version.update_attributes_from_gem_specification!(spec)
  end

  def update_dependencies!(version, spec)
    spec.dependencies.each do |dependency|
      version.dependencies.create!(gem_dependency: dependency)
    end
  rescue ActiveRecord::RecordInvalid => e
    # ActiveRecord can't chain a nested error here, so we have to add and reraise
    errors[:base] << e.message
    raise e
  end

  def update_linkset!(spec)
    self.linkset ||= Linkset.new
    self.linkset.update_attributes_from_gem_specification!(spec)
    self.linkset.save!
  end

  def update_attributes_from_gem_specification!(version, spec)
    Rubygem.transaction do
      save!
      update_versions! version, spec
      update_dependencies! version, spec
      update_linkset! spec if version.reload.latest?
    end
  end

  delegate :count, to: :versions, prefix: true

  def yanked_versions?
    versions.yanked.exists?
  end

  def reorder_versions
    bulk_reorder_versions

    versions_of_platforms = versions
      .release
      .indexed
      .group_by(&:platform)

    versions_of_platforms.each_value do |platforms|
      Version.find(platforms.max.id).update_column(:latest, true)
    end
  end

  def refresh_indexed!
    update!(indexed: versions.indexed.any?)
  end

  def disown
    ownerships_including_unconfirmed.each(&:delete)
    ownerships_including_unconfirmed.clear
  end

  def find_version_from_spec(spec)
    versions.find_by_number_and_platform(spec.version.to_s, spec.original_platform.to_s)
  end

  def find_or_initialize_version_from_spec(spec)
    version = versions.find_or_initialize_by(number: spec.version.to_s,
                                             platform: spec.original_platform.to_s)
    version.rubygem = self
    version
  end

  # returns days left before the reserved namespace will be released
  # 100 + 1 days are added so that last_protected_day / 1.day = 1
  def protected_days
    (updated_at + 101.days - Time.zone.now).to_i / 1.day
  end

  def reverse_dependencies
    self.class.joins("inner join versions as v on v.rubygem_id = rubygems.id
      inner join dependencies as d on d.version_id = v.id").where("v.indexed = 't'
      and v.position = 0 and d.rubygem_id = ?", id)
  end

  def reverse_development_dependencies
    reverse_dependencies.where("d.scope = 'development'")
  end

  def reverse_runtime_dependencies
    reverse_dependencies.where("d.scope ='runtime'")
  end

  def metadata_mfa_required?
    latest_version&.rubygems_metadata_mfa_required?
  end

  def mfa_requirement_satisfied_for?(user)
    user.mfa_enabled? || !metadata_mfa_required?
  end

  # TODO: broken. don't use until #2964 is resolved.
  def mfa_required_since_version
    return unless metadata_mfa_required?
    non_mfa_version = public_versions.find { |v| !v.rubygems_metadata_mfa_required? }
    if non_mfa_version
      non_mfa_version.next.number
    else
      public_versions.last.number
    end
  end

  def release_reserved_namespace!
    update_attribute(:updated_at, 101.days.ago)
  end

  def version_manifest(number, platform = nil)
    VersionManifest.new(gem: name, number: number, platform: platform)
  end

  def file_content(fingerprint)
    RubygemContents.new(gem: name).get(fingerprint)
  end

  private

  # a gem namespace is not protected if it is
  # updated(yanked) in more than 100 days or it is created in last 30 days
  def not_protected?
    updated_at < 100.days.ago || created_at > 30.days.ago
  end

  def ensure_name_format
    if name.class != String
      errors.add :name, "must be a String"
    elsif !/[a-zA-Z]+/.match?(name)
      errors.add :name, "must include at least one letter"
    elsif !NAME_PATTERN.match?(name)
      errors.add :name, "can only include letters, numbers, dashes, and underscores"
    elsif /\A[#{Regexp.escape(Patterns::SPECIAL_CHARACTERS)}]+/o.match?(name)
      errors.add :name, "can not begin with a period, dash, or underscore"
    end
  end

  def needs_name_validation?
    new_record? || name_changed?
  end

  def reserved_names_exclusion
    return unless GEM_NAME_RESERVED_LIST.include? name.downcase
    errors.add :name, "'#{name}' is a reserved gem name."
  end

  def protected_gem_typo
    gem_typo = GemTypo.new(name)

    return unless gem_typo.protected_typo?
    errors.add :name, "'#{name}' is too similar to an existing gem named '#{gem_typo.protected_gem}'"
  end

  def update_unresolved
    Dependency.where(unresolved_name: name).find_each do |dependency|
      dependency.update_resolved(self)
    end
  end

  def mark_unresolved
    Dependency.mark_unresolved_for(self)
  end

  def bulk_reorder_versions
    numbers = reload.versions.sort.reverse.map(&:number).uniq

    ids = []
    positions = []
    versions.each do |version|
      ids << version.id
      positions << numbers.index(version.number)
    end

    update_query = ["update versions set position = positions_data.position, latest = false
      from (select unnest(array[?]) as id, unnest(array[?]) as position) as positions_data
      where versions.id = positions_data.id", ids, positions]

    sanitized_query = ActiveRecord::Base.send(:sanitize_sql_array, update_query)
    ActiveRecord::Base.connection.execute(sanitized_query)
  end
end
