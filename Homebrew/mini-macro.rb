cask "mini-macro" do
  version "0.0.3"
  sha256 "deda8868bd03c4f008d09c4173aac8d9a989b7d485d2a755c0ba8c01bed60c87"

  url "https://github.com/ynifamily3/mini-macro/releases/download/v#{version}/mini-macro-#{version}-universal.dmg"
  name "Mini Macro"
  name "Mouse Macro"
  desc "Mouse macro recorder with a visual automation editor"
  homepage "https://github.com/ynifamily3/mini-macro"

  depends_on macos: :sonoma

  app "Mouse Macro.app"

  zap trash: [
    "~/Library/Application Support/MouseMacro",
    "~/Library/Preferences/ing.miel.mousemacro.plist",
    "~/Library/Saved Application State/ing.miel.mousemacro.savedState",
  ]

  caveats <<~EOS
    The installed app is named Mouse Macro.
    Allow Input Monitoring and Accessibility in System Settings before playback.
    Image IF nodes also require Screen Recording permission.
  EOS
end
