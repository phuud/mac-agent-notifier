cask "mac-agent-notifier" do
  version "0.1.0"
  sha256 "d36c08045de8c27e9d70298c72dd1c5723a69768b0ca34b76a19008aaf4674a6"

  url "https://github.com/phuud/mac-agent-notifier/releases/download/v#{version}/Agent-Notifier-#{version}.dmg"
  name "Agent Notifier"
  desc "Clickable macOS notifications for CLI AI coding agents"
  homepage "https://github.com/phuud/mac-agent-notifier"

  app "Agent Notifier.app"

  postflight do
    system_command "/System/Library/Frameworks/CoreServices.framework/" \
                   "Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister",
                   args: ["-f", "#{appdir}/Agent Notifier.app"]
  end

  uninstall delete: "#{appdir}/Agent Notifier.app"

  zap trash: [
    "~/Library/Preferences/com.phuud.mac-agent-notifier.plist",
  ]
end
