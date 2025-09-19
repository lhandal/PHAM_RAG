# PHAM RAG - Technical Architecture Documentation

## Table of Contents
1. [Project Overview](#project-overview)
2. [Architecture & Technical Workflow](#architecture--technical-workflow)
3. [Key Technical Innovations](#key-technical-innovations)
4. [Implementation Details](#implementation-details)
5. [Evolution & Design Decisions](#evolution--design-decisions)
6. [Developer Handoff Notes](#developer-handoff-notes)

---

## Project Overview

This project implements a **production-grade Retrieval-Augmented Generation (RAG) system** specifically designed for music industry royalty and contract analysis. The system serves as a bilingual data analyst that can answer natural-language questions about contracts, statements, and historical documents while combining structured database lookups with semantic search over ingested text.

The architecture is designed for both **agentic automation** (n8n orchestrations, Supabase functions, Snowflake queries) and **human interaction** (chat interface, Telegram integration). Core principles: precision, auditability, and adaptability to legal/contract data in both Spanish and English.

---

## Architecture & Technical Workflow

### 1. Document Ingestion & Pre-Processing Pipeline

**File Handling:**
- **Supported formats**: PDF, DOCX, TXT, HTML via n8n workflows
- **Text extraction**: Type-specific logic
  - DOCX: Unzip → `document.xml` parsing
  - PDF: Direct text extraction with OCR fallback
  - HTML/TXT: Raw content with UTF-8 normalization
- **Deduplication**: SHA-256 hashing with `record_manager_v2` table
- **Metadata generation**: LLM-powered categorization (PEER, SACM, PHAM, timeframe, language detection)

**Chunking Strategy:**
- **Target size**: 200-300 tokens optimized for `text-embedding-3-small`
- **Semantic boundaries**: Preserves paragraph/section structure
- **Context preservation**: Title and contextual metadata stored separately from chunk content
- **Storage model**: Each chunk = separate row in `documents_v2` with full metadata inheritance

### 2. Embedding Generation & Storage

**Embedding Pipeline:**
- **Model**: OpenAI `text-embedding-3-small` (1536 dimensions)
- **Input**: Raw chunk text only (no title/context concatenation to avoid semantic dilution)
- **Alignment fix**: Embeddings now correctly map to `chunk_index` (resolved duplication bug)
- **Batch processing**: Efficient bulk embedding generation via n8n

**Vector Database:**
- **Platform**: Supabase (PostgreSQL + pgvector)
- **Indexes**: HNSW for vector similarity, GIN for full-text search
- **Bilingual FTS**: Separate `fts_en` and `fts_es` columns using language-specific configurations
- **Metadata model**: Rich document metadata with categorical tagging and temporal indexing

### 3. Hybrid Search Architecture

**Query Processing:**
- **Entry points**: n8n chat interface, Telegram bot integration
- **Query classification**: Lightweight LLM determines semantic vs. exact lookup intent
- **Dynamic weighting**: Hybrid search weights adjusted based on query type

**Core Search Function (`hybrid_search_v2_with_details`):**
```sql
-- Combines vector similarity + full-text search using Reciprocal Rank Fusion (RRF)
-- Deterministic tie-breaking: vector_rank → keyword_rank → file_name → id
-- Supports both cross-lingual and monolingual queries
```

**Ranking Strategy:**
- **Base scoring**: RRF fusion of semantic similarity and keyword relevance
- **Stability guarantee**: Fixed tie-break order ensures consistent results across runs
- **Language handling**: English/Spanish FTS with cross-language semantic matching

### 4. Reranking & Result Optimization

**Reranking Pipeline:**
- **Model**: Cohere v3.5 for semantic reranking of top-k results
- **Stability**: Deterministic tie-break rules maintain consistent rerank output
- **Fallback**: Graceful degradation if reranking service unavailable

**Result Formatting:**
- **Structure**: `title ||| context ||| chunk` for both agent and human consumption
- **Metadata preservation**: Full audit trail with chunk IDs, file sources, and confidence scores
- **Display optimization**: Context-aware snippet generation for UI presentation

### 5. Database Agent & Snowflake Integration

**Intelligent Query Router:**
The system includes a sophisticated **database agent** that automatically determines when to use structured data vs. document search:

- **Query Classification**: LLM-powered intent detection distinguishes between:
  - **Conceptual queries**: "¿Qué son las regalías mecánicas?" → RAG search
  - **Data analysis queries**: "¿Cuánto generó José Alfredo Jiménez en 2024?" → Snowflake
  - **Hybrid queries**: "Explain mechanical royalties and show José's revenue" → Both systems

**Database Agent Architecture:**
```
User Query → Intent Classification → Route Decision
    ↓
    ├── RAG System (Conceptual/Educational)
    ├── Reference DB + Snowflake (Data Analysis)  
    └── Combined Response (Hybrid queries)
```

**Entity Resolution Pipeline:**
- **Supabase Reference Tables**: `authors_ref`, `works_ref`, `lookup_values`
- **Fuzzy Entity Matching**: Author/work name resolution with similarity thresholds (0.3)
- **Bilingual Entity Parsing**: Handles "José Alfredo Jiménez" and "Jose Alfredo Jimenez" variations
- **Time Expression Processing**: 
  - **Semester mapping**: Month 6 (June) = First semester, Month 12 (December) = Second semester
  - **Relative dates**: "último año", "este semestre", "previous quarter"
  - **Cross-language**: "primer semestre 2024" ↔ "Q1 2024"

**Snowflake Query Generation:**
```sql
-- Dynamic query templates with safe parameterization
SELECT {{ revenue_columns }}
FROM {{ $json.config.revenue_table }}
WHERE YEAR = {year}
  [AND AUTHOR_ID = '{author_id}']
  [AND SOURCE IN ({sources})]
  [AND REGION_NAME IN ({regions})]
GROUP BY {{ grouping_columns }}
ORDER BY total_revenue DESC
```

**Publisher Category Intelligence:**
- **PEER Group**: Automatically aggregates Globo Mundo + Globo Productions + Daltex
- **Source categorization**: Maps raw source names to business-meaningful groups
- **Regional expansion**: Supports `region_name` and `region_iso3` columns (implemented for future versions)

**Liberation Rights Management:**
- **Territory-specific queries**: "¿Qué obras están liberadas en México?"
- **Market logic**: USA restrictions automatically apply to Canadian market
- **Rights status filtering**: `mexico=eq.Liberado`, `usa=eq.Restringido`
- **Cross-market analysis**: North America = USA + Canada for rights purposes

**Response Generation & Language Handling:**
- **Language matching**: Responds in user's query language (Spanish/English)
- **Financial formatting**: Proper currency display ($X,XXX.XX) with context
- **Domain terminology**: Uses correct music industry language and concepts
- **Follow-up suggestions**: Contextual next steps based on query results

**Error Handling & Disambiguation:**
- **Multiple author matches**: Presents numbered selection list
- **No data scenarios**: Suggests alternative time periods or entity variations
- **Invalid categories**: Shows valid options from lookup tables
- **Ambiguous queries**: Asks clarifying questions with domain context

**Integration with RAG System:**
- **Seamless handoff**: Database agent queries can trigger RAG searches for context
- **Combined responses**: "Here's José's revenue data, and here's what mechanical royalties mean"
- **Source attribution**: Both database results and document sources properly cited
- **Audit trail**: Complete lineage from user query → entity resolution → SQL execution → response

### 6. Advanced User Experience Features

**Multi-Modal Telegram Integration:**
- **Voice input processing**: Automatic voice-to-text transcription using OpenAI Whisper (ES language optimized)
- **Intelligent response format selection**: Dynamic decision-making between text and audio responses based on:
  - Message content type (lists, data, links = text; conversational = audio)
  - Word count thresholds (short < 20 words = text; long > 50 words = audio)
  - Content complexity analysis
- **TTS audio generation**: High-quality text-to-speech using OpenAI's Nova voice model
- **Session memory**: Chat history maintained per Telegram user ID for context continuity

**User Experience Optimization:**
- **Dual interface support**: Both n8n chat interface and Telegram bot with identical functionality
- **Language preservation**: Maintains user's language preference throughout conversation
- **Context-aware responses**: Session memory with 10-message window for conversation continuity
- **Error handling**: Graceful fallbacks when voice processing or specific tools fail
- **Response formatting**: Automatic formatting optimization for chat vs. document presentation

**Smart Response Logic:**
```javascript
// Dynamic response format selection
const analyzeMessageType = (message) => {
  const wordCount = message.trim().split(/\\s+/).length;
  const hasList = /^\\s*[-•*\\d+\\.]\\s|[-•*]\\s/m.test(message);
  const hasData = /https?:\\/\\/|@\\w+|#\\w+|\\$\\d+|\\d+%/.test(message);
  
  if (hasList || hasData || wordCount < 20) return 'text';
  if (wordCount > 50) return 'audio';
  return /\\b(I think|actually|so|well)\\b/i.test(message) ? 'audio' : 'text';
}
```

**n8n Workflow Orchestration:**
- **Modular design**: Separate workflows for ingestion, search, and data analysis
- **Error handling**: Comprehensive retry logic and failure notifications
- **Monitoring**: Workflow execution logs and performance metrics
- **Version control**: All workflows tracked in Git with deployment automation

**Supabase Functions:**
- **Edge functions**: Low-latency search and embedding operations
- **RLS policies**: Row-level security for multi-tenant document access
- **Real-time sync**: Live updates for document ingestion status
- **Backup strategy**: Automated backups with point-in-time recovery

---

## Key Technical Innovations

### Advanced Multi-Modal Intelligence
- **Voice processing pipeline**: Telegram voice → file download → Whisper transcription → agent processing
- **Response format optimization**: Intelligent selection between text and audio responses based on content analysis
- **Language continuity**: Spanish/English support throughout voice and text interactions
- **Session persistence**: User-specific memory management across conversation sessions

### Enhanced Entity Resolution Pipeline
- **Name normalization**: Automatic accent removal and character standardization for search consistency
- **Multi-step disambiguation**: Structured user interaction for resolving entity conflicts
- **Cross-reference validation**: Coordination between Supabase reference tables and Snowflake data
- **Intent-based routing**: LLM-powered classification determining optimal tool selection

### Clean Embedding Strategy
- **Focused embeddings**: Only chunk text embedded (no title/context pollution)
- **Metadata separation**: Context and titles preserved for display without affecting semantic search
- **Alignment accuracy**: Fixed embedding-to-chunk mapping eliminates index drift

### Bilingual Retrieval System
- **Dual FTS**: Language-specific full-text search with stemming and stop-word handling
- **Cross-language matching**: Semantic embeddings enable Spanish queries to find English content
- **Language detection**: Automatic query language classification for optimal FTS weighting

### Deterministic Hybrid Scoring
- **RRF implementation**: Mathematical fusion of vector similarity and keyword relevance
- **Stable ranking**: Multiple tie-break criteria ensure reproducible results
- **Tunable weights**: Query-intent-based adjustment of semantic vs. keyword importance
- **Audit trail**: Complete scoring breakdown for result explainability

### Agent-Ready Architecture
- **API-first design**: All components accessible via clean REST/RPC interfaces
- **Stateless operations**: No session dependencies, suitable for distributed agent workflows
- **Rich metadata**: Every response includes provenance data for autonomous reasoning
- **Error semantics**: Structured error responses with actionable debugging information

---

## Implementation Details for Developers/Agents

### Database Schema Key Points
```sql
-- documents_v2: Core document storage
-- record_manager_v2: Deduplication and versioning
-- Indexes: hnsw(embedding), gin(fts_en), gin(fts_es)
-- Functions: hybrid_search_v2_with_details, update_search_fields
```

### Implementation Details for Developers/Agents

**Workflow Architecture:**
```json
{
  "trigger_paths": {
    "chat_interface": "When chat message received → Set Config → AI Agent",
    "telegram_voice": "Telegram Trigger → Voice Processing → Transcription → Merge → AI Agent",
    "telegram_text": "Telegram Trigger → Text Processing → Merge → AI Agent"
  },
  "response_paths": {
    "text_response": "AI Agent → Response Analysis → Text Message",
    "audio_response": "AI Agent → Content Analysis → TTS Generation → Audio Message"
  }
}
```

**Critical n8n Node Configurations:**
```javascript
// Supabase Reference Node
{
  "schema": "agent_reference",
  "table": "{{ $fromAI('table_name', 'supabase table to query', 'string') }}",
  "limit": "{{ $fromAI('Limit', '', 'number') }}",
  "filterString": "{{ $fromAI('Filters__String_', '', 'string') }}"
}

// Snowflake Node  
{
  "query": "{{ $fromAI('snowflake_query', 'sql query to search in snowflake', 'string').replace(/\\\\n/g, ' ').replace(/\\\\/g, '') }}"
}

// RAG Tool Workflow
{
  "workflowId": "VXdYIlXAYbEx80si",
  "inputs": {
    "query": "{{ $fromAI('query', $json.query || $json.chatInput || 'test', 'string') }}"
  }
}
```

**Agent System Prompt Structure:**
- **Configuration variables**: Dynamic table/schema references via Set node
- **Tool selection logic**: Explicit routing rules for RAG vs. database vs. hybrid
- **Mandatory workflows**: Step-by-step data analysis process with disambiguation
- **Error handling**: Fallback strategies and graceful degradation
- **Response guidelines**: Language matching and format optimization

### Integration Patterns
- **Document ingestion**: POST to n8n webhook → async processing → Supabase storage
- **Query execution**: Query → classification → hybrid search → optional rerank → response
- **Snowflake fallback**: Numeric queries automatically routed to structured data pipeline
- **Telegram integration**: Real-time chat with voice transcription, intelligent audio/text response selection, and rich formatting

### Monitoring & Debugging
- **Query logs**: Full request/response cycles with timing data
- **Embedding drift**: Monitoring for semantic search quality degradation
- **FTS performance**: Language-specific search effectiveness metrics
- **Rerank stability**: Consistency checking for deterministic outputs

---

## Evolution & Design Decisions

### Why This Architecture
- **Hybrid approach**: Combines semantic understanding with exact keyword matching for legal precision
- **Bilingual core**: Music industry operates globally; Spanish/English support is essential
- **Agent compatibility**: Designed for both human users and autonomous systems
- **Production stability**: Deterministic ranking and comprehensive error handling

### Solved Technical Challenges
1. **Embedding alignment bug**: Fixed chunk-to-embedding mapping inconsistencies
2. **Rerank stability**: Implemented deterministic tie-breaking for consistent results
3. **Bilingual FTS**: Separate language-specific search with cross-language semantic fallback
4. **Context preservation**: Metadata-rich chunking without semantic pollution
5. **Scale optimization**: Efficient indexing and query patterns for large document collections
6. **Database agent routing**: Smart query classification to optimize response strategy
7. **Entity resolution complexity**: Fuzzy matching with disambiguation for music industry entities
8. **Time expression parsing**: Cross-language, industry-specific temporal logic
9. **Liberation rights logic**: Complex territorial restrictions and market mapping
10. **Multi-modal interface**: Voice transcription and intelligent response format selection
11. **Session management**: User-specific memory across conversation sessions
12. **Response optimization**: Dynamic text vs. audio selection based on content analysis

### Future Technical Roadmap
- **Multi-modal support**: Image/table extraction from complex documents
- **Advanced entity linking**: Enhanced resolution for music industry entities
- **Real-time learning**: Feedback loops for improving search relevance
- **Distributed deployment**: Multi-region deployment for global latency optimization

---

## Developer Handoff Notes

**Critical Files/Functions:**
- `hybrid_search_v2_with_details`: Core search RPC function
- `update_search_fields`: FTS vector maintenance
- n8n workflows: Document processing and query orchestration
- Supabase edge functions: Embedding and search API endpoints

**Testing Strategy:**
- Unit tests for chunk generation and embedding alignment
- Integration tests for hybrid search ranking consistency
- End-to-end tests for bilingual query scenarios
- Performance tests for large document collections

**Deployment Dependencies:**
- OpenAI API access for embeddings
- Cohere API for reranking
- Supabase project with pgvector extension
- n8n instance with required integrations
- Snowflake warehouse for structured data

This documentation serves as both a technical specification and a knowledge transfer document for continued development by human developers or autonomous agents.