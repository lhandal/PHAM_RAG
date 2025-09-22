#!/usr/bin/env python3
"""
PHAM RAG Prompt Synchronization Script
Updates system prompts across all N8N workflows automatically.
"""

import json
import os
import sys
from pathlib import Path
from typing import Dict, List, Any

# Colors for output
class Colors:
    GREEN = '\033[0;32m'
    BLUE = '\033[0;34m'
    YELLOW = '\033[1;33m'
    RED = '\033[0;31m'
    NC = '\033[0m'  # No Color

def log(color: str, message: str):
    """Print colored log message"""
    print(f"{color}{message}{Colors.NC}")

def load_prompt() -> str:
    """Load the system prompt from the text file"""
    prompt_file = Path("prompts/system_prompt.txt")
    
    if not prompt_file.exists():
        raise FileNotFoundError(f"Prompt file not found: {prompt_file}")
    
    with open(prompt_file, 'r', encoding='utf-8') as f:
        content = f.read().strip()
    
    log(Colors.BLUE, f"📄 Loaded system prompt ({len(content)} chars)")
    return content

def find_workflow_files() -> List[Path]:
    """Find all workflow JSON files"""
    workflow_dir = Path("n8n/workflows")
    
    if not workflow_dir.exists():
        raise FileNotFoundError(f"Workflow directory not found: {workflow_dir}")
    
    workflows = list(workflow_dir.glob("*.json"))
    log(Colors.BLUE, f"🔍 Found {len(workflows)} workflow files")
    return workflows

def update_workflow_prompt(workflow_path: Path, new_prompt: str) -> bool:
    """Update the system prompt in a workflow file"""
    try:
        # Load workflow
        with open(workflow_path, 'r', encoding='utf-8') as f:
            workflow = json.load(f)
        
        updated = False
        
        # Check each node for AI Agent nodes with systemMessage
        for node in workflow.get('nodes', []):
            # Look for AI Agent nodes with system messages
            if (node.get('type') == '@n8n/n8n-nodes-langchain.agent' and 
                'parameters' in node and 
                'options' in node['parameters'] and
                'systemMessage' in node['parameters']['options']):
                
                old_prompt = node['parameters']['options']['systemMessage']
                
                # Check if this contains our target prompt
                if "Unified Music Royalty Agent - Complete System Prompt" in old_prompt:
                    # Extract the variable part (if any) - everything before the prompt
                    if old_prompt.startswith('='):
                        # This is an expression, update the content after the =
                        node['parameters']['options']['systemMessage'] = f"={new_prompt}"
                    else:
                        # Direct string
                        node['parameters']['options']['systemMessage'] = new_prompt
                    
                    updated = True
                    log(Colors.GREEN, f"  ✅ Updated AI Agent node: {node.get('name', 'unnamed')}")
        
        # Save if updated
        if updated:
            with open(workflow_path, 'w', encoding='utf-8') as f:
                json.dump(workflow, f, indent=2, ensure_ascii=False)
            return True
        
        return False
        
    except Exception as e:
        log(Colors.RED, f"  ❌ Error updating {workflow_path.name}: {str(e)}")
        return False

def main():
    """Main synchronization function"""
    try:
        log(Colors.BLUE, "🚀 Starting PHAM RAG prompt synchronization...")
        
        # Change to project root
        project_root = Path(__file__).parent.parent
        os.chdir(project_root)
        
        # Load new prompt
        new_prompt = load_prompt()
        
        # Find workflows
        workflows = find_workflow_files()
        
        # Update each workflow
        updated_count = 0
        total_count = len(workflows)
        
        for workflow_path in workflows:
            log(Colors.YELLOW, f"🔧 Processing: {workflow_path.name}")
            
            if update_workflow_prompt(workflow_path, new_prompt):
                updated_count += 1
            else:
                log(Colors.YELLOW, f"  ⏭️  No prompt found in {workflow_path.name}")
        
        # Summary
        log(Colors.BLUE, "📊 Synchronization Summary")
        print("----------------------------------------")
        print(f"📊 Total Workflows: {total_count}")
        print(f"📊 Updated Workflows: {updated_count}")
        print(f"📊 Unchanged Workflows: {total_count - updated_count}")
        print("----------------------------------------")
        
        if updated_count > 0:
            log(Colors.GREEN, "🎉 Prompt synchronization completed successfully!")
            log(Colors.YELLOW, "💡 Remember to run the sync script to commit changes to Git")
        else:
            log(Colors.YELLOW, "ℹ️  No workflows needed updating")
            
    except Exception as e:
        log(Colors.RED, f"❌ Synchronization failed: {str(e)}")
        sys.exit(1)

if __name__ == "__main__":
    main()