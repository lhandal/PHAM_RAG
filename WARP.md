# WARP.md

This file provides guidance to WARP (warp.dev) when working with code in this repository.

## Project Overview

PHAM RAG is a production-grade **Retrieval-Augmented Generation (RAG) system** specifically designed for music industry royalty and contract analysis. The system combines N8N workflow orchestration, Supabase vector database, Snowflake data warehouse, and AI agents to provide bilingual (Spanish/English) intelligent analysis of music contracts, statements, and revenue data.

**Core Capabilities:**
- Document-based knowledge retrieval with semantic search
- Structured database analysis for revenue/royalty data
- Hybrid search combining vector similarity and keyword matching
- Multi-modal interface (text and voice via Telegram)
- Intelligent query routing between conceptual and data analysis tools
- Bilingual operation with cross-language semantic matching

## Essential Commands

### Development Setup
```bash
# Initial setup
cp .env.example .env
# Edit .env with your API keys and URLs

# Install dependencies (if package.json exists)
npm install

# Link Supabase project
supabase login
supabase link --project-ref your-project-ref
```

### Core Workflow Operations
```bash
# Export all N8N workflows tagged "PHAM RAG"
N8N_URL="https://your-instance.app.n8n.cloud/api/v1" \
N8N_API_KEY="your-api-key" \
node n8n/scripts/export_all.mjs

# Sync system prompts across all workflows
python3 scripts/sync_prompt.py

# Full automated sync (exports from N8N & Supabase, commits to Git)
./scripts/sync.sh "Your commit message"

# Run with debug output
DEBUG=1 ./scripts/sync.sh "Debug sync"
```

### Supabase Operations
```bash
# Export database schema
supabase db dump --schema public > supabase/sql/full_schema.sql

# Generate TypeScript types
supabase gen types typescript --project-id PROJECT_REF > supabase/types/generated/database.types.ts

# Deploy edge functions
supabase functions deploy hybrid-search-v2
```

### Testing and Verification
```bash
# Test N8N API connectivity
curl -H "X-N8N-API-KEY: $N8N_API_KEY" "$N8N_URL/workflows"

# Check workflow count
find n8n/workflows -name "*.json" | wc -l

# Verify Supabase connection
supabase status
```

## Architecture Overview

### Multi-Agent System Design
The system implements a sophisticated **query routing architecture** that automatically determines the optimal tools for each user request:

**Query Classification Pipeline:**
1. **RAG System**: For conceptual questions, explanations, industry knowledge
2. **Reference DB + Snowflake**: For specific revenue data, author/work analytics  
3. **Hybrid Approach**: Combines both for comprehensive responses

**Critical Architecture Components:**
- **N8N Workflow Orchestration**: 6 core workflows handling different aspects of the system
- **Supabase Vector Database**: Document storage, embeddings, hybrid search functions
- **Snowflake Integration**: Revenue and analytics data warehouse
- **Telegram Bot**: Multi-modal interface with voice transcription and intelligent response formatting

### Data Flow Architecture
```
User Query → Intent Classification → Route Decision
    ↓
    ├── RAG System (Conceptual/Educational)
    ├── Reference DB + Snowflake (Data Analysis)  
    └── Combined Response (Hybrid queries)
```

### Key Technical Innovations

**Hybrid Search System:**
- **Vector Similarity**: OpenAI `text-embedding-3-small` (1536 dimensions)
- **Full-Text Search**: Bilingual FTS with language-specific configurations (`fts_en`, `fts_es`)
- **Reciprocal Rank Fusion (RRF)**: Mathematical fusion with deterministic tie-breaking
- **Cohere Reranking**: Optional semantic reranking for result optimization

**Bilingual Intelligence:**
- **Cross-language matching**: Spanish queries can find English content via semantic embeddings
- **Language preservation**: System responds in user's query language
- **Entity resolution**: Handles accent variations and name normalization

**Multi-Modal Interface:**
- **Voice Processing**: Telegram voice → Whisper transcription → agent processing
- **Intelligent Response Format**: Dynamic selection between text/audio based on content analysis
- **Session Memory**: User-specific conversation context across sessions

## Critical File Locations

### Configuration Files
- `.env` - Environment variables (API keys, URLs)
- `.env.example` - Template for environment setup
- `prompts/system_prompt.txt` - Master AI agent system prompt (289 lines)

### N8N Workflows (`n8n/workflows/`)
All workflows are tagged "PHAM RAG" and include:
- `database-agent.json` - SQL query generation and execution
- `multi-agent.json` - Agent orchestration and task delegation  
- `pham-rag-basic-.json` - Core RAG implementation
- `load-documents.json` - Document ingestion and processing
- `vector-search.json` - Semantic similarity search
- `rag-agent.json` - Advanced RAG with agent capabilities

### Supabase Components
- `supabase/functions/hybrid-search-v2/` - Core search RPC function
- `supabase/sql/` - Database schema and migrations
- `supabase/types/` - TypeScript type definitions
- `supabase/.temp/project-ref` - Project linking configuration

### Scripts
- `scripts/sync.sh` - Main automation script (310 lines)
- `scripts/sync_prompt.py` - System prompt synchronization
- `n8n/scripts/export_all.mjs` - N8N workflow export

## Database Schema Knowledge

### Supabase Tables (Reference Data)
```sql
-- documents_v2: Core document storage with embeddings
-- record_manager_v2: Deduplication and versioning
-- authors_ref: Author information with IDs
-- works_ref: Musical works with legacy_identifiers
-- lookup_values: Categories (sources, publishers, etc.)
```

### Snowflake Revenue Table
```sql
-- Key columns for analytics:
-- LEGACY_IDENTIFIER, AUTHOR_ID, ROW_AMOUNT_USD, YEAR, MONTH
-- LIQUIDATION_PERCENTAGE, CONTRACT_PUBLISHER_SHARE
-- REGION_NAME, SOURCE, ROYALTY_TYPE
```

## Entity Resolution Patterns

**Author Search Process:**
1. Extract name → search `authors_ref.full_name`
2. If multiple matches → **STOP** and present disambiguation list
3. User selects → proceed with verified `author_id`

**Work Identification:**
1. Author's works: `works_ref.authors_jsonb=cs.[{"author_id":"ABC123"}]`
2. Title search: `works_ref.title=ilike.*normalized_title*`
3. Collect `legacy_identifier` values for Snowflake queries

**Critical Rule:** Never reference Supabase tables in Snowflake queries - only use collected `legacy_identifier` values.

## Time Expression Processing

**Semester Mapping:**
- Month 6 (June) = First semester
- Month 12 (December) = Second semester

**Cross-Language Support:**
- "último año" ↔ "last year" 
- "primer semestre 2024" ↔ "Q1 2024"
- "este mes" ↔ "this month"

## Development Workflow

### Making Changes
1. **Modify workflows** in N8N interface
2. **Tag new workflows** with "PHAM RAG" 
3. **Update system prompts** in `prompts/system_prompt.txt`
4. **Run synchronization**:
   ```bash
   python3 scripts/sync_prompt.py  # Update prompts in workflows
   ./scripts/sync.sh "Describe your changes"  # Export and commit
   ```

### Prompt Management
The system uses a centralized prompt in `prompts/system_prompt.txt` that gets synchronized across all AI agent nodes in N8N workflows. The prompt includes:
- Tool selection logic (289 lines of detailed instructions)
- Mandatory workflow completion rules
- Query routing strategies
- Entity resolution patterns
- Bilingual operation guidelines

### Testing Integration Points
```bash
# Test hybrid search function
curl -X POST "https://PROJECT.supabase.co/functions/v1/hybrid-search-v2" \
  -H "Authorization: Bearer $SUPABASE_ANON_KEY" \
  -H "Content-Type: application/json" \
  -d '{"query": "mechanical royalties", "limit": 5}'

# Verify N8N workflow tags
curl -H "X-N8N-API-KEY: $N8N_API_KEY" "$N8N_URL/workflows?tags=PHAM%20RAG"
```

## Common Issues and Solutions

### N8N Export Problems
- **Check API key validity** and URL format
- **Verify workflow tagging** with "PHAM RAG"
- **Review rate limits** and network connectivity

### Supabase Connection Issues  
- **Re-authenticate**: `supabase login`
- **Check project linking**: `supabase status`
- **Verify environment variables** in `.env`

### Embedding Alignment Issues
The system has resolved previous embedding-to-chunk mapping inconsistencies. If search results seem misaligned:
- Check `documents_v2` table for proper `chunk_index` mapping
- Verify embeddings match actual chunk content
- Review `hybrid_search_v2_with_details` function stability

### Multi-Language Search Problems
- **FTS Configuration**: Ensure separate `fts_en` and `fts_es` columns exist
- **Query Language Detection**: System should automatically detect and route appropriately  
- **Cross-language Fallback**: Semantic embeddings should bridge language gaps

## Agent Interaction Patterns

When working with this system, understand that it's designed for **both human users and autonomous agents**:

### For Human Developers
- Use the sync script for version control
- Modify prompts centrally and synchronize  
- Test workflows in N8N interface first

### For AI Agents
- System provides rich metadata and provenance data
- API-first design supports stateless operations
- Structured error responses enable autonomous debugging
- Complete audit trails for all operations

### Query Examples for Testing
```
# RAG (conceptual) queries:
"¿Qué son las regalías mecánicas?"
"Explain music publishing"
"How does ASCAP work?"

# Data analysis queries:  
"¿Cuánto generó José Alfredo Jiménez en 2024?"
"Top works by this author"
"Regional revenue breakdown"

# Hybrid queries:
"Explain mechanical royalties and show José's mechanical revenue"
"What is ASCAP and show ASCAP revenue data"
```

## Production Considerations

**Monitoring Points:**
- Query response times and accuracy
- Embedding drift detection
- FTS performance across languages
- Rerank stability and consistency
- Workflow execution success rates

**Scalability Factors:**
- Document collection size impacts search performance
- Snowflake query optimization for large datasets
- N8N workflow concurrency limits
- Supabase connection pooling

**Security Considerations:**
- API keys stored in environment variables only
- Row-level security policies in Supabase
- Sensitive data excluded via `.gitignore`
- Regular key rotation for production access