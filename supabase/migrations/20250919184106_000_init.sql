create schema if not exists "agent_reference";

create sequence "agent_reference"."lookup_values_id_seq";

create table "agent_reference"."authors_ref" (
    "author_id" text not null,
    "full_name" text,
    "first_name" text,
    "first_last_name" text,
    "second_last_name" text,
    "pseudonym" text,
    "normalized_name" text,
    "search_vector" tsvector,
    "created_at" timestamp with time zone default now(),
    "updated_at" timestamp with time zone default now()
);


alter table "agent_reference"."authors_ref" enable row level security;

create table "agent_reference"."liberation_reference" (
    "legacy_identifier" bigint,
    "version" text,
    "title" text,
    "publisher" text,
    "catalog" text,
    "mexico" text,
    "usa_canada" text,
    "latam" text,
    "sapan_portugal" text,
    "brazil" text,
    "rest_of_world" text
);


alter table "agent_reference"."liberation_reference" enable row level security;

create table "agent_reference"."lookup_values" (
    "id" integer not null default nextval('agent_reference.lookup_values_id_seq'::regclass),
    "category" text not null,
    "value" text not null,
    "group_name" text,
    "sort_order" integer default 0,
    "active" boolean default true,
    "created_at" timestamp with time zone default now()
);


alter table "agent_reference"."lookup_values" enable row level security;

create table "agent_reference"."works_ref" (
    "legacy_identifier" text not null,
    "title" text,
    "authors" json,
    "normalized_title" text,
    "authors_jsonb" jsonb,
    "search_vector" tsvector,
    "created_at" timestamp with time zone default now(),
    "updated_at" timestamp with time zone default now(),
    "mexico" text,
    "usa" text,
    "latam" text,
    "spain_portugal" text,
    "brazil" text,
    "rest_of_world" text
);


alter table "agent_reference"."works_ref" enable row level security;

alter sequence "agent_reference"."lookup_values_id_seq" owned by "agent_reference"."lookup_values"."id";

CREATE UNIQUE INDEX authors_ref_pkey ON agent_reference.authors_ref USING btree (author_id);

CREATE INDEX idx_authors_normalized_name ON agent_reference.authors_ref USING gin (normalized_name gin_trgm_ops);

CREATE INDEX idx_authors_pseudonym ON agent_reference.authors_ref USING btree (pseudonym) WHERE (pseudonym IS NOT NULL);

CREATE INDEX idx_authors_search_vector ON agent_reference.authors_ref USING gin (search_vector);

CREATE INDEX idx_lookup_category ON agent_reference.lookup_values USING btree (category);

CREATE INDEX idx_lookup_group ON agent_reference.lookup_values USING btree (group_name) WHERE (group_name IS NOT NULL);

CREATE INDEX idx_works_authors_jsonb ON agent_reference.works_ref USING gin (authors_jsonb);

CREATE INDEX idx_works_normalized_title ON agent_reference.works_ref USING gin (normalized_title gin_trgm_ops);

CREATE INDEX idx_works_search_vector ON agent_reference.works_ref USING gin (search_vector);

CREATE UNIQUE INDEX lookup_values_category_value_key ON agent_reference.lookup_values USING btree (category, value);

CREATE UNIQUE INDEX lookup_values_pkey ON agent_reference.lookup_values USING btree (id);

alter table "agent_reference"."authors_ref" add constraint "authors_ref_pkey" PRIMARY KEY using index "authors_ref_pkey";

alter table "agent_reference"."lookup_values" add constraint "lookup_values_pkey" PRIMARY KEY using index "lookup_values_pkey";

alter table "agent_reference"."lookup_values" add constraint "lookup_values_category_value_key" UNIQUE using index "lookup_values_category_value_key";

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION agent_reference.search_authors(search_term text)
 RETURNS TABLE(author_id text, full_name text, first_name text, first_last_name text, second_last_name text, pseudonym text, similarity_score real)
 LANGUAGE plpgsql
AS $function$
BEGIN
    RETURN QUERY
    SELECT 
        a.author_id,
        a.full_name,
        a.first_name,
        a.first_last_name,
        a.second_last_name,
        a.pseudonym,
        similarity(a.normalized_name, lower(unaccent(search_term))) as similarity_score
    FROM agent_reference.authors_ref a
    WHERE a.normalized_name % lower(unaccent(search_term))
       OR a.search_vector @@ plainto_tsquery('spanish', search_term)
    ORDER BY similarity_score DESC, ts_rank(a.search_vector, plainto_tsquery('spanish', search_term)) DESC
    LIMIT 5;
END;
$function$
;

CREATE OR REPLACE FUNCTION agent_reference.search_works(search_term text)
 RETURNS TABLE(legacy_identifier text, title text, authors_jsonb jsonb, similarity_score real)
 LANGUAGE plpgsql
AS $function$
BEGIN
    RETURN QUERY
    SELECT 
        w.legacy_identifier,
        w.title,
        w.authors_jsonb,
        similarity(w.normalized_title, lower(unaccent(search_term))) as similarity_score
    FROM agent_reference.works_ref w
    WHERE w.normalized_title % lower(unaccent(search_term))
       OR w.search_vector @@ plainto_tsquery('spanish', search_term)
    ORDER BY similarity_score DESC, ts_rank(w.search_vector, plainto_tsquery('spanish', search_term)) DESC
    LIMIT 5;
END;
$function$
;

create or replace view "agent_reference"."source_groups" as  SELECT group_name,
    array_agg(value ORDER BY sort_order) AS sources
   FROM agent_reference.lookup_values
  WHERE ((category = 'source'::text) AND (group_name IS NOT NULL))
  GROUP BY group_name;


CREATE OR REPLACE FUNCTION agent_reference.update_search_fields()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    -- For authors table
    IF TG_TABLE_NAME = 'authors_ref' THEN
        NEW.normalized_name := lower(unaccent(COALESCE(NEW.full_name, '')));
        NEW.search_vector := to_tsvector('spanish', 
            COALESCE(NEW.full_name, '') || ' ' ||
            COALESCE(NEW.first_name, '') || ' ' ||
            COALESCE(NEW.first_last_name, '') || ' ' ||
            COALESCE(NEW.second_last_name, '') || ' ' ||
            COALESCE(NEW.pseudonym, '')
        );
        NEW.updated_at := NOW();
    END IF;
    
    -- For works table
    IF TG_TABLE_NAME = 'works_ref' THEN
        NEW.normalized_title := lower(unaccent(COALESCE(NEW.title, '')));
        NEW.search_vector := to_tsvector('spanish', COALESCE(NEW.title, '')); 
        NEW.updated_at := NOW();
        
        -- Optionally parse authors JSON to authors_jsonb if not provided
        IF NEW.authors_jsonb IS NULL AND NEW.authors IS NOT NULL THEN
            NEW.authors_jsonb := NEW.authors::jsonb;
        END IF;
    END IF;
    
    RETURN NEW;
END;
$function$
;

create policy "Enable read access for all users"
on "agent_reference"."authors_ref"
as permissive
for select
to public
using (true);


create policy "Enable read access for all users"
on "agent_reference"."lookup_values"
as permissive
for select
to public
using (true);


create policy "Enable read access for all users"
on "agent_reference"."works_ref"
as permissive
for select
to public
using (true);


CREATE TRIGGER trigger_authors_search_fields BEFORE INSERT OR UPDATE ON agent_reference.authors_ref FOR EACH ROW EXECUTE FUNCTION agent_reference.update_search_fields();

CREATE TRIGGER trigger_works_search_fields BEFORE INSERT OR UPDATE ON agent_reference.works_ref FOR EACH ROW EXECUTE FUNCTION agent_reference.update_search_fields();


create extension if not exists "pg_trgm" with schema "public" version '1.6';

create extension if not exists "unaccent" with schema "public" version '1.1';

create extension if not exists "vector" with schema "public" version '0.8.0';

create sequence "public"."documents_id_seq";

create table "public"."documents" (
    "id" bigint not null default nextval('documents_id_seq'::regclass),
    "content" text,
    "metadata" jsonb,
    "embedding" vector(1536)
);


alter table "public"."documents" enable row level security;

create table "public"."documents_v2" (
    "id" uuid not null default gen_random_uuid(),
    "content" text not null,
    "metadata" jsonb not null default '{}'::jsonb,
    "lang" text not null,
    "embedding" vector(1536),
    "fts_en" tsvector,
    "fts_es" tsvector,
    "file_name" text
);


create table "public"."record_manager" (
    "id" bigint generated by default as identity not null,
    "created_at" timestamp with time zone not null default now(),
    "google_drive_file_id" text not null,
    "hash" text not null,
    "file_name" text
);


alter table "public"."record_manager" enable row level security;

create table "public"."record_manager_v2" (
    "id" bigint generated by default as identity not null,
    "created_at" timestamp with time zone not null default now(),
    "google_drive_file_id" text not null,
    "hash" text not null,
    "file_name" text
);


alter sequence "public"."documents_id_seq" owned by "public"."documents"."id";

CREATE UNIQUE INDEX documents_pkey ON public.documents USING btree (id);

CREATE INDEX documents_v2_embedding_hnsw ON public.documents_v2 USING hnsw (embedding vector_cosine_ops);

CREATE INDEX documents_v2_fts_en_gin ON public.documents_v2 USING gin (fts_en);

CREATE INDEX documents_v2_fts_es_gin ON public.documents_v2 USING gin (fts_es);

CREATE INDEX documents_v2_meta_category_gin ON public.documents_v2 USING gin (((metadata -> 'category'::text)));

CREATE INDEX documents_v2_meta_filename_trgm ON public.documents_v2 USING gin (((metadata ->> 'file_name'::text)) gin_trgm_ops);

CREATE UNIQUE INDEX documents_v2_pkey ON public.documents_v2 USING btree (id);

CREATE INDEX idx_documents_v2_file_name_ci ON public.documents_v2 USING btree (lower(file_name));

CREATE INDEX idx_documents_v2_file_name_trgm ON public.documents_v2 USING gin (lower(file_name) gin_trgm_ops);

CREATE UNIQUE INDEX record_manager_pkey ON public.record_manager USING btree (id);

CREATE UNIQUE INDEX record_manager_v2_pkey ON public.record_manager_v2 USING btree (id);

alter table "public"."documents" add constraint "documents_pkey" PRIMARY KEY using index "documents_pkey";

alter table "public"."documents_v2" add constraint "documents_v2_pkey" PRIMARY KEY using index "documents_v2_pkey";

alter table "public"."record_manager" add constraint "record_manager_pkey" PRIMARY KEY using index "record_manager_pkey";

alter table "public"."record_manager_v2" add constraint "record_manager_v2_pkey" PRIMARY KEY using index "record_manager_v2_pkey";

alter table "public"."documents_v2" add constraint "documents_v2_lang_check" CHECK ((lang = ANY (ARRAY['en'::text, 'es'::text]))) not valid;

alter table "public"."documents_v2" validate constraint "documents_v2_lang_check";

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.documents_v2_fill_from_metadata()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  -- Prefer values provided in JSON metadata
  if new.file_name is null then
    new.file_name := new.metadata->>'file_name';
  end if;

  -- Language: prefer metadata-provided; only fallback if absent
  if new.lang is null then
    new.lang := new.metadata->>'lang';
  end if;
  if new.lang is null then
    -- ultra-light fallback; replace if you have a detector
    new.lang := case when new.content ~ '[A-Za-z]' then 'en' else 'es' end;
  end if;

  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.documents_v2_fts_refresh()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  new.fts_en := to_tsvector('english', unaccent(coalesce(new.content,'')));
  new.fts_es := to_tsvector('spanish', unaccent(coalesce(new.content,'')));
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.hybrid_search_v2(query_text text, query_embedding vector, match_count integer DEFAULT 5, filter jsonb DEFAULT '{}'::jsonb, lang text DEFAULT 'auto'::text, full_text_weight double precision DEFAULT 1.5, semantic_weight double precision DEFAULT 2.0, rrf_k integer DEFAULT 50)
 RETURNS TABLE(id uuid, content text, metadata jsonb, file_name text, lang text, embedding vector, fts_en tsvector, fts_es tsvector, vector_score double precision, keyword_score double precision, vector_rank bigint, keyword_rank bigint, final_score double precision)
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
  SELECT *
  FROM public.hybrid_search_v2_with_details(
    p_query_text        => query_text,
    p_query_embedding   => query_embedding,
    p_match_count       => match_count,
    p_filter            => filter,
    p_lang              => lang,
    p_full_text_weight  => full_text_weight,
    p_semantic_weight   => semantic_weight,
    p_rrf_k             => rrf_k
  );
$function$
;

CREATE OR REPLACE FUNCTION public.hybrid_search_v2_with_details(p_query_text text, p_query_embedding vector, p_match_count integer, p_filter jsonb, p_lang text, p_full_text_weight double precision, p_semantic_weight double precision, p_rrf_k integer)
 RETURNS TABLE(id uuid, content text, metadata jsonb, file_name text, doc_lang text, vector_score double precision, keyword_score double precision, vector_rank integer, keyword_rank integer, final_score double precision)
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_lang text := COALESCE(NULLIF(TRIM(p_lang), ''), 'auto');
  v_rrf  integer := GREATEST(p_rrf_k, 1);
BEGIN
  RETURN QUERY
  WITH q AS (
    SELECT
      plainto_tsquery('english', unaccent(p_query_text))  AS q_en,
      plainto_tsquery('spanish', unaccent(p_query_text))  AS q_es
  ),
  norm_filter AS (
    SELECT CASE
      WHEN p_filter IS NULL
        OR jsonb_typeof(p_filter) <> 'object'
        OR NULLIF(TRIM(COALESCE(p_filter->>'category','')), '') IS NULL
        OR upper(p_filter->>'category') = 'N/A'
      THEN '{}'::jsonb
      ELSE jsonb_build_object('category', replace(p_filter->>'category',' ',''))
    END AS f
  ),
  kv AS (
    SELECT key, f->>key AS raw
    FROM norm_filter, LATERAL jsonb_object_keys(f) AS k(key)
  ),
  kv_values AS (
    SELECT key, trim(val) AS val
    FROM kv, LATERAL unnest(string_to_array(COALESCE(raw,''), ';')) AS u(val)
    WHERE COALESCE(raw,'') <> ''
  ),
  filtered AS (
    SELECT
      d.id            AS doc_id,
      d.content       AS content,
      d.metadata      AS metadata,
      d.lang          AS doc_lang,
      d.embedding     AS embedding,
      d.fts_en        AS fts_en,
      d.fts_es        AS fts_es
    FROM documents_v2 d
    WHERE NOT EXISTS (
      SELECT 1
      FROM (SELECT key FROM norm_filter, LATERAL jsonb_object_keys(f) AS k(key)) k
      WHERE NOT EXISTS (
        SELECT 1
        FROM kv_values v
        WHERE v.key = k.key
          AND (
            (jsonb_typeof(d.metadata -> v.key) = 'array' AND (d.metadata -> v.key) ? v.val)
            OR (d.metadata ->> v.key) ILIKE ('%' || v.val || '%')
          )
      )
    )
  ),
  vector_ranked AS (
    SELECT
      f.doc_id,
      (1 - (f.embedding <=> p_query_embedding))::double precision AS vector_score,
      dense_rank() OVER (ORDER BY (1 - (f.embedding <=> p_query_embedding)) DESC)::int AS vector_rank
    FROM filtered f
  ),
  keyword_scored AS (
    SELECT
      f.doc_id,
      (
        CASE
          WHEN v_lang = 'en' THEN ts_rank_cd(f.fts_en, (SELECT q_en FROM q))
          WHEN v_lang = 'es' THEN ts_rank_cd(f.fts_es, (SELECT q_es FROM q))
          ELSE GREATEST(
                 ts_rank_cd(f.fts_en, (SELECT q_en FROM q)),
                 ts_rank_cd(f.fts_es, (SELECT q_es FROM q))
               )
        END
      )::double precision AS keyword_score
    FROM filtered f
  ),
  keyword_ranked AS (
    SELECT
      ks.doc_id,
      ks.keyword_score,
      dense_rank() OVER (ORDER BY ks.keyword_score DESC)::int AS keyword_rank
    FROM keyword_scored ks
  ),
  combined AS (
    SELECT
      f.doc_id,
      f.content,
      f.metadata,
      f.doc_lang,
      vr.vector_score,
      kr.keyword_score,
      COALESCE(vr.vector_rank,  1000000000) AS vector_rank,
      COALESCE(kr.keyword_rank, 1000000000) AS keyword_rank
    FROM filtered f
    LEFT JOIN vector_ranked  vr ON vr.doc_id = f.doc_id
    LEFT JOIN keyword_ranked kr ON kr.doc_id = f.doc_id
  )
  SELECT
    c.doc_id                                        AS id,
    c.content                                       AS content,
    c.metadata                                      AS metadata,
    c.metadata->>'file_name'                        AS file_name,
    c.doc_lang                                      AS doc_lang,
    c.vector_score                                  AS vector_score,
    c.keyword_score                                 AS keyword_score,
    c.vector_rank                                   AS vector_rank,
    c.keyword_rank                                  AS keyword_rank,
    (
      p_semantic_weight / (v_rrf + c.vector_rank)::double precision
      +
      p_full_text_weight / (v_rrf + c.keyword_rank)::double precision
    )::double precision                              AS final_score
  FROM combined c
  ORDER BY final_score DESC
  LIMIT p_match_count;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.hybrid_search_v2_with_details_debug(p_query_text text, p_query_embedding vector, p_match_count integer, p_filter jsonb, p_lang text, p_full_text_weight double precision, p_semantic_weight double precision, p_rrf_k integer)
 RETURNS TABLE(id uuid, content text, metadata jsonb, file_name text, doc_lang text, vector_score double precision, keyword_score double precision, vector_rank integer, keyword_rank integer, final_score double precision, q_es text, q_en text, r_es double precision, r_en double precision, used_lang text, used_tsquery text)
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_lang text := COALESCE(NULLIF(TRIM(p_lang), ''), 'auto');
  v_rrf  integer := GREATEST(p_rrf_k, 1);
BEGIN
  RETURN QUERY
  WITH q AS (
    SELECT
      websearch_to_tsquery('spanish', unaccent(p_query_text))  AS q_es,
      websearch_to_tsquery('english', unaccent(p_query_text))  AS q_en
  ),
  norm_filter AS (
    SELECT CASE
      WHEN p_filter IS NULL
        OR jsonb_typeof(p_filter) <> 'object'
        OR NULLIF(TRIM(COALESCE(p_filter->>'category','')), '') IS NULL
        OR upper(p_filter->>'category') = 'N/A'
      THEN '{}'::jsonb
      ELSE jsonb_build_object('category', replace(p_filter->>'category',' ',''))
    END AS f
  ),
  kv AS (
    SELECT key, f->>key AS raw
    FROM norm_filter, LATERAL jsonb_object_keys(f) AS k(key)
  ),
  kv_values AS (
    SELECT key, trim(val) AS val
    FROM kv, LATERAL unnest(string_to_array(COALESCE(raw,''), ';')) AS u(val)
    WHERE COALESCE(raw,'') <> ''
  ),
  filtered AS (
    SELECT
      d.id         AS doc_id,
      d.content    AS content,
      d.metadata   AS metadata,
      d.lang       AS doc_lang,
      d.embedding  AS embedding,
      d.fts_en     AS fts_en,
      d.fts_es     AS fts_es
    FROM documents_v2 d
    WHERE NOT EXISTS (
      SELECT 1
      FROM (SELECT key FROM norm_filter, LATERAL jsonb_object_keys(f) AS k(key)) k
      WHERE NOT EXISTS (
        SELECT 1
        FROM kv_values v
        WHERE v.key = k.key
          AND (
            (jsonb_typeof(d.metadata -> v.key) = 'array' AND (d.metadata -> v.key) ? v.val)
            OR (d.metadata ->> v.key) ILIKE ('%' || v.val || '%')
          )
      )
    )
  ),
  vector_ranked AS (
    SELECT
      f.doc_id,
      (1 - (f.embedding <=> p_query_embedding))::double precision AS vector_score,
      dense_rank() OVER (ORDER BY (1 - (f.embedding <=> p_query_embedding)) DESC)::int AS vector_rank
    FROM filtered f
  ),
  keyword_scored AS (
    SELECT
      f.doc_id,
      ts_rank_cd(f.fts_es, (SELECT q.q_es FROM q))::double precision AS r_es,
      ts_rank_cd(f.fts_en, (SELECT q.q_en FROM q))::double precision AS r_en,
      CASE
        WHEN v_lang = 'es' THEN ts_rank_cd(f.fts_es, (SELECT q.q_es FROM q))
        WHEN v_lang = 'en' THEN ts_rank_cd(f.fts_en, (SELECT q.q_en FROM q))
        ELSE GREATEST(ts_rank_cd(f.fts_es, (SELECT q.q_es FROM q)),
                      ts_rank_cd(f.fts_en, (SELECT q.q_en FROM q)))
      END::double precision AS keyword_score,
      CASE
        WHEN v_lang = 'es' THEN 'es'
        WHEN v_lang = 'en' THEN 'en'
        ELSE CASE WHEN ts_rank_cd(f.fts_es, (SELECT q.q_es FROM q)) >= ts_rank_cd(f.fts_en, (SELECT q.q_en FROM q))
                  THEN 'es' ELSE 'en' END
      END AS used_lang
    FROM filtered f
  ),
  keyword_ranked AS (
    SELECT
      ks.doc_id,
      ks.r_es,
      ks.r_en,
      ks.keyword_score,
      ks.used_lang,
      dense_rank() OVER (ORDER BY ks.keyword_score DESC)::int AS keyword_rank
    FROM keyword_scored ks
  ),
  combined AS (
    SELECT
      f.doc_id,
      f.content,
      f.metadata,
      f.doc_lang,
      vr.vector_score,
      kr.keyword_score,
      COALESCE(vr.vector_rank,  1000000000) AS vector_rank,
      COALESCE(kr.keyword_rank, 1000000000) AS keyword_rank,
      kr.r_es,
      kr.r_en,
      kr.used_lang
    FROM filtered f
    LEFT JOIN vector_ranked  vr ON vr.doc_id = f.doc_id
    LEFT JOIN keyword_ranked kr ON kr.doc_id = f.doc_id
  )
  SELECT
    c.doc_id                                        AS id,
    c.content                                       AS content,
    c.metadata                                      AS metadata,
    c.metadata->>'file_name'                        AS file_name,
    c.doc_lang                                      AS doc_lang,
    c.vector_score                                  AS vector_score,
    c.keyword_score                                 AS keyword_score,
    c.vector_rank                                   AS vector_rank,
    c.keyword_rank                                  AS keyword_rank,
    (
      p_semantic_weight / (v_rrf + c.vector_rank)::double precision
      +
      p_full_text_weight / (v_rrf + c.keyword_rank)::double precision
    )::double precision                              AS final_score,
    -- DEBUG OUTPUTS (fully qualified to avoid ambiguity with OUT vars)
    (SELECT q.q_es::text FROM q)                    AS q_es,
    (SELECT q.q_en::text FROM q)                    AS q_en,
    c.r_es                                          AS r_es,
    c.r_en                                          AS r_en,
    c.used_lang                                     AS used_lang,
    CASE c.used_lang
      WHEN 'es' THEN (SELECT q.q_es::text FROM q)
      ELSE (SELECT q.q_en::text FROM q)
    END                                             AS used_tsquery
  FROM combined c
  ORDER BY final_score DESC
  LIMIT p_match_count;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.match_documents(query_embedding vector, match_count integer DEFAULT NULL::integer, filter jsonb DEFAULT '{}'::jsonb)
 RETURNS TABLE(id bigint, content text, metadata jsonb, similarity double precision)
 LANGUAGE plpgsql
AS $function$begin
  return query
  with kv as (
    select key, filter->>key as raw
    from jsonb_object_keys(filter) k(key)
  ),
  kv_expanded as (
    select key, trim(val) as val
    from kv, unnest(string_to_array(coalesce(raw,''), ';')) u(val)
    where coalesce(raw,'') <> ''
  ),
  matched_docs as (
    select d.*
    from documents d
    where not exists (
      select 1
      from jsonb_object_keys(filter) k(key)
      where not exists (
        select 1
        from kv_expanded v
        where v.key = k.key
          and (
            (jsonb_typeof(d.metadata -> v.key) = 'array' and (d.metadata -> v.key) ? v.val)
            or (d.metadata ->> v.key) ilike ('%' || v.val || '%')
          )
      )
    )
  )
  select
    md.id          as id,
    md.content     as content,
    md.metadata    as metadata,
    1 - (md.embedding <=> query_embedding) as similarity
  from matched_docs md
  order by md.embedding <=> query_embedding
  limit match_count;
end;$function$
;

CREATE OR REPLACE FUNCTION public.set_lang_from_metadata()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  -- If metadata has a lang field, use it
  if NEW.metadata ? 'lang' then
    NEW.lang := NEW.metadata->>'lang';
  end if;
  return NEW;
end;
$function$
;

CREATE TRIGGER documents_v2_fts_refresh_ins BEFORE INSERT ON public.documents_v2 FOR EACH ROW EXECUTE FUNCTION documents_v2_fts_refresh();

CREATE TRIGGER documents_v2_fts_refresh_upd BEFORE UPDATE OF content ON public.documents_v2 FOR EACH ROW EXECUTE FUNCTION documents_v2_fts_refresh();

CREATE TRIGGER trg_documents_v2_fill_from_metadata BEFORE INSERT OR UPDATE ON public.documents_v2 FOR EACH ROW EXECUTE FUNCTION documents_v2_fill_from_metadata();

CREATE TRIGGER trg_set_lang_from_metadata BEFORE INSERT OR UPDATE ON public.documents_v2 FOR EACH ROW EXECUTE FUNCTION set_lang_from_metadata();


