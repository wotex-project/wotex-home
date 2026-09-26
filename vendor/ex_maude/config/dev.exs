import Config

config :ex_maude,
  pool_size: 4,
  pool_max_overflow: 2

config :git_ops,
  mix_project: Mix.Project.get!(),
  changelog_file: "CHANGELOG.md",
  repository_url: "https://github.com/futhr/ex_maude",
  version_tag_prefix: "v",
  manage_mix_version?: true,
  manage_readme_version: "README.md"
