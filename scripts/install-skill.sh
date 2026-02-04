#!/bin/bash
#
# install-skill.sh - Download and install skills from agent-skills.md
#
# Usage:
#   ./scripts/install-skill.sh <skill-source>
#
# Examples:
#   # Install from a GitHub URL (skills folder)
#   ./scripts/install-skill.sh https://github.com/owner/repo/tree/main/skills/my-skill
#
#   # Install from a GitHub URL (entire skill folder)
#   ./scripts/install-skill.sh https://github.com/owner/repo
#
#   # Install using owner/repo/skill-name format
#   ./scripts/install-skill.sh owner/repo/skill-name
#
# Skills are installed to .agent/skills/<skill-name>/
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SKILLS_DIR=".agent/skills"
API_BASE="https://api.github.com"

# Check dependencies
check_dependencies() {
    local missing=()
    
    if ! command -v curl &> /dev/null; then
        missing+=("curl")
    fi
    
    if ! command -v jq &> /dev/null; then
        missing+=("jq")
    fi
    
    if [ ${#missing[@]} -ne 0 ]; then
        echo -e "${RED}Error: Missing required dependencies: ${missing[*]}${NC}"
        echo "Please install them before running this script."
        exit 1
    fi
}

# Parse GitHub URL to extract owner, repo, and path
parse_github_url() {
    local input="$1"
    
    # Remove trailing .git
    input="${input%.git}"
    
    # Handle direct owner/repo/path format
    if [[ "$input" =~ ^([^/]+)/([^/]+)(/(.*))?$ ]]; then
        OWNER="${BASH_REMATCH[1]}"
        REPO="${BASH_REMATCH[2]}"
        SKILL_PATH="${BASH_REMATCH[4]}"
        return 0
    fi
    
    # Handle full GitHub URLs
    if [[ "$input" =~ github\.com/([^/]+)/([^/]+)(/tree/[^/]+/(.*))?$ ]] || \
       [[ "$input" =~ github\.com/([^/]+)/([^/]+)(/blob/[^/]+/(.*))?$ ]]; then
        OWNER="${BASH_REMATCH[1]}"
        REPO="${BASH_REMATCH[2]}"
        SKILL_PATH="${BASH_REMATCH[4]}"
        return 0
    fi
    
    # Simple github.com/owner/repo
    if [[ "$input" =~ github\.com/([^/]+)/([^/]+)$ ]]; then
        OWNER="${BASH_REMATCH[1]}"
        REPO="${BASH_REMATCH[2]}"
        SKILL_PATH=""
        return 0
    fi
    
    return 1
}

# Fetch default branch of a repository
get_default_branch() {
    local owner="$1"
    local repo="$2"
    
    local response
    response=$(curl -s -H "Accept: application/vnd.github+json" \
        ${GITHUB_TOKEN:+-H "Authorization: Bearer $GITHUB_TOKEN"} \
        "$API_BASE/repos/$owner/$repo")
    
    echo "$response" | jq -r '.default_branch // "main"'
}

# Fetch repository tree
fetch_repo_tree() {
    local owner="$1"
    local repo="$2"
    local branch="$3"
    
    curl -s -H "Accept: application/vnd.github+json" \
        ${GITHUB_TOKEN:+-H "Authorization: Bearer $GITHUB_TOKEN"} \
        "$API_BASE/repos/$owner/$repo/git/trees/$branch?recursive=1"
}

# Fetch file content from GitHub
fetch_file_content() {
    local owner="$1"
    local repo="$2"
    local path="$3"
    
    local response
    response=$(curl -s -H "Accept: application/vnd.github+json" \
        ${GITHUB_TOKEN:+-H "Authorization: Bearer $GITHUB_TOKEN"} \
        "$API_BASE/repos/$owner/$repo/contents/$path")
    
    # Decode base64 content
    echo "$response" | jq -r '.content // empty' | base64 -d 2>/dev/null || echo ""
}

# Parse skill name from SKILL.md frontmatter
parse_skill_name() {
    local content="$1"
    
    # Extract name from YAML frontmatter
    echo "$content" | sed -n '/^---$/,/^---$/p' | grep -E '^name:' | sed 's/name:\s*//' | tr -d '"'"'" | tr -d ' '
}

# Find skills in a repository path
find_skills() {
    local tree_json="$1"
    local base_path="$2"
    
    local prefix=""
    if [ -n "$base_path" ]; then
        prefix="${base_path}/"
    fi
    
    # Find all SKILL.md files (handle null paths gracefully)
    echo "$tree_json" | jq -r '.tree[] | select(.type == "blob" and .path != null and (.path | endswith("/SKILL.md"))) | .path' 2>/dev/null | \
        while read -r skill_path; do
            # If base_path is set, only include skills under that path
            if [ -n "$base_path" ]; then
                if [[ "$skill_path" == "$prefix"* ]]; then
                    echo "$skill_path"
                fi
            else
                echo "$skill_path"
            fi
        done
}

# Download a skill folder
download_skill() {
    local owner="$1"
    local repo="$2"
    local skill_folder_path="$3"
    local tree_json="$4"
    
    # Get skill name from folder path
    local skill_name
    skill_name=$(basename "$skill_folder_path")
    
    # Fetch SKILL.md to get the actual name
    local skill_md_content
    skill_md_content=$(fetch_file_content "$owner" "$repo" "$skill_folder_path/SKILL.md")
    
    if [ -z "$skill_md_content" ]; then
        echo -e "${RED}Error: Could not fetch SKILL.md from $skill_folder_path${NC}"
        return 1
    fi
    
    # Parse skill name from frontmatter
    local parsed_name
    parsed_name=$(parse_skill_name "$skill_md_content")
    if [ -n "$parsed_name" ]; then
        skill_name="$parsed_name"
    fi
    
    local target_dir="$SKILLS_DIR/$skill_name"
    
    echo -e "${BLUE}Installing skill: ${GREEN}$skill_name${NC}"
    echo -e "  Source: github.com/$owner/$repo/$skill_folder_path"
    echo -e "  Target: $target_dir"
    
    # Create target directory
    mkdir -p "$target_dir"
    
    # Find all files in this skill folder
    prefix="${skill_folder_path}/"
    local files
    files=$(echo "$tree_json" | jq -r ".tree[] | select(.type == \"blob\" and (.path | startswith(\"$prefix\"))) | .path")
    
    # Also include the SKILL.md at the root of the skill folder
    files="$skill_folder_path/SKILL.md
$files"
    
    # Download each file
    while IFS= read -r file_path; do
        if [ -z "$file_path" ]; then
            continue
        fi
        
        # Calculate relative path within skill folder
        local relative_path="${file_path#$skill_folder_path/}"
        local target_file="$target_dir/$relative_path"
        local target_file_dir
        target_file_dir=$(dirname "$target_file")
        
        # Create subdirectories if needed
        mkdir -p "$target_file_dir"
        
        # Fetch and save file
        echo -e "  ${YELLOW}↓${NC} $relative_path"
        fetch_file_content "$owner" "$repo" "$file_path" > "$target_file"
    done <<< "$files"
    
    echo -e "${GREEN}✓ Installed $skill_name${NC}"
    echo ""
}

# Main function
main() {
    if [ $# -lt 1 ]; then
        echo "Usage: $0 <skill-source>"
        echo ""
        echo "Examples:"
        echo "  $0 https://github.com/owner/repo/tree/main/skills/my-skill"
        echo "  $0 owner/repo/skill-name"
        echo "  $0 owner/repo  # Lists available skills"
        echo ""
        echo "Environment variables:"
        echo "  GITHUB_TOKEN - GitHub API token for higher rate limits"
        exit 1
    fi
    
    check_dependencies
    
    local input="$1"
    
    if ! parse_github_url "$input"; then
        echo -e "${RED}Error: Could not parse GitHub URL: $input${NC}"
        exit 1
    fi
    
    echo -e "${BLUE}Fetching repository: ${GREEN}$OWNER/$REPO${NC}"
    
    # Get default branch
    local branch
    branch=$(get_default_branch "$OWNER" "$REPO")
    echo -e "  Branch: $branch"
    
    # Fetch repository tree
    local tree_json
    tree_json=$(fetch_repo_tree "$OWNER" "$REPO" "$branch")
    
    if [ "$(echo "$tree_json" | jq -r '.tree // empty')" == "" ]; then
        echo -e "${RED}Error: Could not fetch repository tree${NC}"
        echo "$tree_json" | jq -r '.message // "Unknown error"'
        exit 1
    fi
    
    # Common skill paths to search
    local skill_search_paths=(
        ""
        "skills"
        ".agent/skills"
        ".agents/skills"
        ".claude/skills"
        ".cursor/skills"
        ".gemini/skills"
        ".github/skills"
    )
    
    # If a specific path was provided, use it
    if [ -n "$SKILL_PATH" ]; then
        # Check if it's a direct skill folder (contains SKILL.md)
        local direct_skill_md="$SKILL_PATH/SKILL.md"
        local has_skill_md
        has_skill_md=$(echo "$tree_json" | jq -r ".tree[] | select(.type == \"blob\" and .path == \"$direct_skill_md\") | .path")
        
        if [ -n "$has_skill_md" ]; then
            # It's a direct skill folder, download it
            download_skill "$OWNER" "$REPO" "$SKILL_PATH" "$tree_json"
            exit 0
        fi
        
        # Otherwise, search for skills under this path
        skill_search_paths=("$SKILL_PATH")
    fi
    
    # Find all skills
    local found_skills=()
    for search_path in "${skill_search_paths[@]}"; do
        local skills
        skills=$(find_skills "$tree_json" "$search_path")
        
        while IFS= read -r skill_path; do
            if [ -n "$skill_path" ]; then
                # Get the skill folder (parent of SKILL.md)
                local skill_folder
                skill_folder=$(dirname "$skill_path")
                found_skills+=("$skill_folder")
            fi
        done <<< "$skills"
    done
    
    # Remove duplicates
    local unique_skills
    unique_skills=($(printf "%s\n" "${found_skills[@]}" | sort -u))
    
    if [ ${#unique_skills[@]} -eq 0 ]; then
        echo -e "${YELLOW}No skills found in repository${NC}"
        exit 0
    fi
    
    echo -e "${GREEN}Found ${#unique_skills[@]} skill(s):${NC}"
    for skill_folder in "${unique_skills[@]}"; do
        echo -e "  • $skill_folder"
    done
    echo ""
    
    # Download each skill
    for skill_folder in "${unique_skills[@]}"; do
        download_skill "$OWNER" "$REPO" "$skill_folder" "$tree_json"
    done
    
    echo -e "${GREEN}Done! Skills installed to $SKILLS_DIR/${NC}"
}

main "$@"
