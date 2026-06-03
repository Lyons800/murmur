cask "sotto" do
  version "1.1.0"
  sha256 :no_check

  url "https://github.com/Lyons800/sotto/releases/download/v#{version}/Sotto.dmg"
  name "Sotto"
  desc "On-device voice-to-text for macOS — hold a key, speak, release"
  homepage "https://sotto.audio"

  depends_on macos: ">= :sonoma"
  depends_on arch: :arm64

  app "Sotto.app"

  zap trash: [
    "~/Library/Application Support/Sotto",
    "~/Library/Preferences/audio.sotto.plist",
    "~/Library/Caches/audio.sotto",
  ]
end
