cask "mini-macro" do
  version "0.0.1"
  sha256 "80470a99ff3e2dfcbb7555e0c8990ffec6aee1125310abec84950e5932fc91a6"

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
