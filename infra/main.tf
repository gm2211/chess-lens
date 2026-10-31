terraform {
  required_providers {
    github = {
      source  = "integrations/github"
      version = "~> 6.0"
    }
  }
}

# Auth via GITHUB_TOKEN (bootstrap secret): GITHUB_TOKEN=$(gh auth token) terraform apply
provider "github" {}

resource "github_repository" "chess_lens" {
  name        = "chess-lens"
  description = "Native macOS chess analysis: read a board from a screenshot, analyze with Stockfish 18, AI review via your own ChatGPT plan (BYOS)."
  visibility  = "public"
  topics      = ["chess", "macos", "swiftui", "stockfish", "computer-vision", "chess-analysis"]

  has_issues   = true
  has_projects = false
  has_wiki     = false

  allow_merge_commit     = false
  allow_rebase_merge     = false
  allow_squash_merge     = true
  delete_branch_on_merge = true
}

output "repo_ssh_url" {
  value = github_repository.chess_lens.ssh_clone_url
}

output "repo_html_url" {
  value = github_repository.chess_lens.html_url
}
