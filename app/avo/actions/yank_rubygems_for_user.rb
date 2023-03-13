class YankRubygemsForUser < BaseAction
  self.name = "Yank all Rubygems"
  self.visible = lambda {
    current_user.team_member?("rubygems-org") &&
    view == :show &&
    resource.model.rubygems.present?
  }

  self.message = lambda {
    "Are you sure you would like to yank all rubygems for user #{record.handle} with #{record.email}?"
  }

  self.confirm_button_label = "Yank all Rubygems"

  class ActionHandler < ActionHandler
    def handle_model(user)
      security_user = User.find_by!(email: "security@rubygems.org")

      user.rubygems.each do |rubygem|
        rubygem.versions do |version|
          security_user.deletions.create!(version: version) unless version.yanked?
        end
      end
    end
  end
end
