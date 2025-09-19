#!/bin/bash

# PHAM RAG Sync Script
# Downloads data from Supabase and N8N, then commits to GitHub
# Usage: ./scripts/sync.sh "Your commit message"

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
COMMIT_MESSAGE="${1:-"Automated sync: $(date '+%Y-%m-%d %H:%M:%S')"}"
DEBUG="${DEBUG:-0}"

# Load environment variables if .env exists
if [ -f "$PROJECT_ROOT/.env" ]; then
    source "$PROJECT_ROOT/.env"
    echo -e "${BLUE}ℹ️  Loaded environment variables from .env${NC}"
fi

# Function to print colored output
log() {
    local color=$1
    local message=$2
    echo -e "${color}${message}${NC}"
}

# Function to print debug messages
debug() {
    if [ "$DEBUG" = "1" ]; then
        log $YELLOW "🐛 DEBUG: $1"
    fi
}

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to check prerequisites
check_prerequisites() {
    log $BLUE "🔍 Checking prerequisites..."
    
    local missing_commands=()
    
    if ! command_exists "node"; then
        missing_commands+=("node")
    fi
    
    if ! command_exists "git"; then
        missing_commands+=("git")
    fi
    
    if ! command_exists "supabase"; then
        missing_commands+=("supabase")
    fi
    
    if ! command_exists "curl"; then
        missing_commands+=("curl")
    fi
    
    if [ ${#missing_commands[@]} -ne 0 ]; then
        log $RED "❌ Missing required commands: ${missing_commands[*]}"
        log $YELLOW "Please install the missing commands and try again."
        exit 1
    fi
    
    log $GREEN "✅ All prerequisites satisfied"
}

# Function to validate environment variables
validate_environment() {
    log $BLUE "🔧 Validating environment..."
    
    local missing_vars=()
    
    if [ -z "$N8N_URL" ]; then
        missing_vars+=("N8N_URL")
    fi
    
    if [ -z "$N8N_API_KEY" ]; then
        missing_vars+=("N8N_API_KEY")
    fi
    
    if [ ${#missing_vars[@]} -ne 0 ]; then
        log $RED "❌ Missing required environment variables: ${missing_vars[*]}"
        log $YELLOW "Please set them in .env file or export them in your shell."
        exit 1
    fi
    
    log $GREEN "✅ Environment variables validated"
}

# Function to export N8N workflows
export_n8n_workflows() {
    log $BLUE "📥 Exporting N8N workflows..."
    
    cd "$PROJECT_ROOT"
    
    # Count existing workflows
    local existing_count=0
    if [ -d "n8n/workflows" ]; then
        existing_count=$(find n8n/workflows -name "*.json" | wc -l | tr -d ' ')
    fi
    
    debug "Existing workflows: $existing_count"
    debug "N8N_URL: $N8N_URL"
    debug "Running export script..."
    
    # Run the N8N export script
    if N8N_URL="$N8N_URL" N8N_API_KEY="$N8N_API_KEY" node n8n/scripts/export_all.mjs; then
        local new_count=$(find n8n/workflows -name "*.json" | wc -l | tr -d ' ')
        log $GREEN "✅ Successfully exported $new_count N8N workflows"
        debug "New workflow count: $new_count"
    else
        log $RED "❌ Failed to export N8N workflows"
        return 1
    fi
}

# Function to export Supabase data
export_supabase_data() {
    log $BLUE "🗄️  Exporting Supabase data..."
    
    cd "$PROJECT_ROOT"
    
    # Check if supabase is linked
    if ! supabase status >/dev/null 2>&1; then
        log $YELLOW "⚠️  Supabase project not linked. Skipping Supabase export."
        log $YELLOW "   Run 'supabase link --project-ref your-project-ref' to link the project."
        return 0
    fi
    
    debug "Supabase project is linked"
    
    # Export database schema
    log $BLUE "  📋 Exporting database schema..."
    if supabase db dump --schema public > supabase/sql/full_schema.sql 2>/dev/null; then
        log $GREEN "  ✅ Database schema exported"
    else
        log $YELLOW "  ⚠️  Failed to export database schema (continuing anyway)"
    fi
    
    # Generate TypeScript types
    log $BLUE "  📝 Generating TypeScript types..."
    if supabase gen types typescript --local > supabase/types/generated/database.types.ts 2>/dev/null; then
        log $GREEN "  ✅ TypeScript types generated"
    else
        log $YELLOW "  ⚠️  Failed to generate TypeScript types (continuing anyway)"
    fi
    
    # List functions (they're already in the functions directory)
    local function_count=0
    if [ -d "supabase/functions" ]; then
        function_count=$(find supabase/functions -name "index.ts" | wc -l | tr -d ' ')
    fi
    
    log $GREEN "✅ Supabase export completed ($function_count functions found)"
    debug "Function count: $function_count"
}

# Function to check for changes
check_for_changes() {
    log $BLUE "🔍 Checking for changes..."
    
    cd "$PROJECT_ROOT"
    
    # Check if there are any changes
    if git diff --quiet && git diff --staged --quiet; then
        log $YELLOW "📝 No changes detected. Nothing to commit."
        return 1
    fi
    
    # Show what changed
    log $BLUE "📋 Changes detected:"
    git status --porcelain | while read -r line; do
        log $YELLOW "  $line"
    done
    
    return 0
}

# Function to commit and push changes
commit_and_push() {
    log $BLUE "📤 Committing and pushing changes..."
    
    cd "$PROJECT_ROOT"
    
    # Add all changes
    git add .
    
    # Create detailed commit message
    local detailed_message="$COMMIT_MESSAGE

Automated sync performed at $(date '+%Y-%m-%d %H:%M:%S')

Changes include:
- N8N workflows (tagged: PHAM RAG)
- Supabase schema and types
- Function updates"
    
    debug "Commit message: $detailed_message"
    
    # Commit changes
    if git commit -m "$detailed_message"; then
        log $GREEN "✅ Changes committed successfully"
    else
        log $RED "❌ Failed to commit changes"
        return 1
    fi
    
    # Push to remote
    if git push origin main; then
        log $GREEN "✅ Changes pushed to GitHub successfully"
    else
        log $RED "❌ Failed to push changes to GitHub"
        return 1
    fi
}

# Function to show summary
show_summary() {
    log $BLUE "📊 Sync Summary"
    echo "----------------------------------------"
    
    # Count workflows
    local workflow_count=0
    if [ -d "n8n/workflows" ]; then
        workflow_count=$(find n8n/workflows -name "*.json" | wc -l | tr -d ' ')
    fi
    
    # Count functions
    local function_count=0
    if [ -d "supabase/functions" ]; then
        function_count=$(find supabase/functions -name "index.ts" | wc -l | tr -d ' ')
    fi
    
    # Show git log
    local last_commit=$(git log --oneline -1)
    
    echo "📊 N8N Workflows: $workflow_count"
    echo "📊 Supabase Functions: $function_count"
    echo "📊 Last Commit: $last_commit"
    echo "📊 Repository: $(git remote get-url origin)"
    echo "----------------------------------------"
    
    log $GREEN "🎉 Sync completed successfully!"
}

# Main execution
main() {
    log $GREEN "🚀 Starting PHAM RAG sync process..."
    
    # Change to project root
    cd "$PROJECT_ROOT"
    debug "Project root: $PROJECT_ROOT"
    debug "Commit message: $COMMIT_MESSAGE"
    
    # Run all steps
    check_prerequisites
    validate_environment
    
    export_n8n_workflows
    export_supabase_data
    
    if check_for_changes; then
        commit_and_push
        show_summary
    else
        log $GREEN "🎉 Sync completed - no changes to commit"
    fi
}

# Handle script interruption
trap 'log $RED "❌ Script interrupted"; exit 1' INT TERM

# Help message
if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    echo "PHAM RAG Sync Script"
    echo "Usage: $0 [commit-message]"
    echo ""
    echo "Options:"
    echo "  -h, --help    Show this help message"
    echo ""
    echo "Environment variables:"
    echo "  N8N_URL       N8N API URL (required)"
    echo "  N8N_API_KEY   N8N API key (required)"
    echo "  DEBUG         Set to 1 for debug output"
    echo ""
    echo "Examples:"
    echo "  $0 \"Add new workflow\""
    echo "  DEBUG=1 $0 \"Debug sync\""
    exit 0
fi

# Run main function
main "$@"