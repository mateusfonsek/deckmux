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

  # The Deckmux icon in the terminal, shown after install and upgrade.
  caveats <<~EOS
    \e[90m╭──────────────╮\e[0m
    \e[90m│\e[0m \e[2;36m>_\e[0m           \e[90m│\e[0m   \e[1mDeckmux #{version}\e[0m
    \e[90m│\e[0m     \e[96m█  █\e[0m     \e[90m│\e[0m   Um terminal para quem roda vários agentes.
    \e[90m╰──────────────╯\e[0m   Abra pelo Launchpad ou: \e[1mopen -a Deckmux\e[0m
                       Novidades: https://github.com/mateusfonsek/deckmux/releases/tag/v#{version}
  EOS
end
