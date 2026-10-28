cask "deckmux" do
  version "@VERSION@"
  sha256 "@SHA256@"

  url "https://github.com/mateusfonsek/deckmux/releases/download/v#{version}/Deckmux-#{version}-universal.dmg"
  name "Deckmux"
  desc "Command center for Claude Code with libghostty terminals by workspace"
  homepage "https://github.com/mateusfonsek/deckmux"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :sonoma

  app "Deckmux.app"

  # Deckmux is not signed with an Apple Developer ID, so macOS would block
  # its first launch; installing from this tap is the user's go-ahead.
  postflight_steps do
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{appdir}}/Deckmux.app"],
                          writable_paths: ["Deckmux.app"], writable_base: :appdir
  end

  zap trash: [
    "~/Library/Application Support/Deckmux",
    "~/Library/Preferences/dev.fonsek.deckmux.plist",
    "~/Library/Saved Application State/dev.fonsek.deckmux.savedState",
  ]
end
