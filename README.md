# PHAM RAG - Retrieval-Augmented Generation System

A comprehensive RAG (Retrieval-Augmented Generation) system built with N8N workflows, Supabase database, and AI agents for intelligent document processing and question answering.

## 🏗️ Project Structure

```
PHAM_RAG/
├── README.md                     # This file
├── .gitignore                   # Git ignore rules
├── scripts/                     # Automation scripts
│   └── sync.sh                 # Sync script for versioning
├── n8n/                        # N8N workflows and scripts
│   ├── scripts/
│   │   └── export_all.mjs      # N8N workflow export script
│   └── workflows/              # Exported N8N workflows (tagged: PHAM RAG)
│       ├── database-agent.json
│       ├── multi-agent.json
│       ├── pham-rag-basic-.json
│       ├── load-documents.json
│       ├── vector-search.json
│       └── rag-agent.json
└── supabase/                   # Supabase configuration and database
    ├── functions/              # Edge functions
    │   └── hybrid-search-v2/
    ├── migrations/             # Database migrations  
    ├── sql/                   # SQL schemas and queries
    ├── types/                 # TypeScript type definitions
    └── .temp/                 # Temporary Supabase files
```

## 🚀 Quick Start

### Prerequisites

- Node.js (v18 or higher)
- Supabase CLI
- N8N Cloud account or local instance
- Git with SSH authentication to GitHub

### Environment Variables

Create a `.env` file in the project root:

```bash
# N8N Configuration
N8N_URL="https://your-instance.app.n8n.cloud/api/v1"
N8N_API_KEY="your-n8n-api-key"

# Supabase Configuration  
SUPABASE_PROJECT_URL="https://your-project.supabase.co"
SUPABASE_ANON_KEY="your-anon-key"
SUPABASE_SERVICE_ROLE_KEY="your-service-role-key"

# GitHub Configuration (optional - uses SSH by default)
GITHUB_TOKEN="your-github-token"
```

### Installation

1. **Clone the repository:**
   ```bash
   git clone git@github.com:lhandal/PHAM_RAG.git
   cd PHAM_RAG
   ```

2. **Install dependencies:**
   ```bash
   npm install
   ```

3. **Setup Supabase:**
   ```bash
   supabase login
   supabase link --project-ref your-project-ref
   ```

4. **Setup N8N API access:**
   - Generate an API key in your N8N instance
   - Tag relevant workflows with "PHAM RAG"

## 📖 Documentation

- **[README.md](README.md)** - Setup, usage, and maintenance (this file)
- **[ARCHITECTURE.md](ARCHITECTURE.md)** - Technical architecture and implementation details
- **[N8N Workflows](n8n/workflows/)** - Exported workflow configurations

## 🏗️ Architecture Overview

This project implements a sophisticated **music industry RAG system** that combines document-based knowledge retrieval with real-time database analysis. The system features **hybrid search** (vector similarity + keyword matching), **multi-modal interface** supporting voice and text via Telegram, **intelligent database agent** for revenue/royalty analysis, and **bilingual support** for Spanish and English queries. Built with n8n workflow orchestration, Supabase vector database, and OpenAI models, it serves both human users and autonomous agents with production-grade reliability and auditability.

For detailed technical architecture, implementation patterns, and developer guidance, see [ARCHITECTURE.md](ARCHITECTURE.md).

## 🎯 Core Components

### N8N Workflows

The system includes 6 main workflows tagged with "PHAM RAG":

1. **Database Agent** (`database-agent.json`)
   - Intelligent SQL query generation and execution
   - Natural language to database queries
   - Multi-table relationship handling

2. **Multi Agent** (`multi-agent.json`)  
   - Orchestrates multiple AI agents
   - Task delegation and coordination
   - Complex workflow management

3. **PHAM RAG Basic** (`pham-rag-basic-.json`)
   - Core RAG implementation
   - Document retrieval and generation
   - Basic question-answering pipeline

4. **Load Documents** (`load-documents.json`)
   - Document ingestion and processing
   - Text extraction and chunking
   - Vector embedding generation

5. **Vector Search** (`vector-search.json`)
   - Semantic similarity search
   - Vector database queries
   - Retrieval optimization

6. **RAG Agent** (`rag-agent.json`)
   - Advanced RAG with agent capabilities
   - Context-aware responses
   - Dynamic knowledge retrieval

### Supabase Database

- **Hybrid Search Function**: Advanced search combining semantic and keyword search
- **Vector Storage**: Optimized for AI embeddings
- **Real-time Capabilities**: Live data synchronization
- **Edge Functions**: Serverless compute for AI operations

## 🔄 Automated Versioning

Use the sync script to automatically version your changes:

```bash
# Make the script executable
chmod +x scripts/sync.sh

# Run the sync (downloads from Supabase & N8N, commits to GitHub)
./scripts/sync.sh "Your commit message"
```

The script will:
1. Export latest N8N workflows (tagged "PHAM RAG")  
2. Download current Supabase schema and functions
3. Generate updated TypeScript types
4. Commit and push changes to GitHub

## 📚 Usage Examples

### Manual N8N Export

Export workflows manually:

```bash
N8N_URL="https://your-instance.app.n8n.cloud/api/v1" \
N8N_API_KEY="your-api-key" \
node n8n/scripts/export_all.mjs
```

### Manual Supabase Schema Export

Export database schema:

```bash
supabase db dump --schema public > supabase/sql/schema.sql
supabase gen types typescript --local > supabase/types/database.types.ts
```

### Development Workflow

1. **Make changes** in N8N workflows or Supabase
2. **Tag workflows** with "PHAM RAG" if new
3. **Run sync script**:
   ```bash
   ./scripts/sync.sh "Add new document processing workflow"
   ```
4. **Review changes** in GitHub

## 🔧 Configuration

### N8N Workflow Tagging

To include workflows in version control:
1. Open workflow in N8N
2. Go to workflow settings  
3. Add tag: "PHAM RAG"
4. Save workflow

### Supabase Functions

Edge functions are automatically included:
- Located in `supabase/functions/`
- Deployed with `supabase functions deploy`
- Versioned with each sync

## 🚨 Troubleshooting

### Common Issues

**N8N Export Fails:**
- Check API key validity
- Verify N8N URL format
- Ensure workflows are tagged correctly

**Supabase Connection Issues:**
- Run `supabase login` to re-authenticate
- Check project reference with `supabase status`
- Verify environment variables

**Git Push Failures:**
- Check SSH key authentication
- Verify repository permissions
- Review commit message format

### Debug Mode

Run scripts with debug output:

```bash
DEBUG=1 ./scripts/sync.sh "Debug commit"
```

## 🤝 Contributing

1. Fork the repository
2. Create a feature branch: `git checkout -b feature/new-agent`
3. Make your changes in N8N and/or Supabase
4. Run the sync script: `./scripts/sync.sh "Add new agent feature"`
5. Open a Pull Request

## 📝 Version History

Changes are automatically tracked through git commits. Each sync creates a detailed commit with:
- Timestamp
- Changed workflows
- Database schema updates
- Function modifications

View history: `git log --oneline`

## 🛡️ Security

- API keys are stored in environment variables
- Sensitive data excluded via `.gitignore`
- Secret scanning enabled on GitHub
- Service keys rotated regularly

## 📄 License

This project is licensed under the MIT License - see the LICENSE file for details.

## 🔗 Links

- [N8N Documentation](https://docs.n8n.io/)
- [Supabase Documentation](https://supabase.com/docs)
- [Project Repository](https://github.com/lhandal/PHAM_RAG)

## 📧 Support

For questions or issues:
- Open a GitHub issue
- Check existing documentation
- Review troubleshooting section

---

*Last updated: $(date)*