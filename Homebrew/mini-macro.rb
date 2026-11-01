cask "mini-macro" do
  version "0.0.2"
  sha256 "a359be77e3ced294dc46710535b1b5e0cb626b232c9f48e045b34d159b632380"

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
