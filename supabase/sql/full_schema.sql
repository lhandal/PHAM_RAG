

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE SCHEMA IF NOT EXISTS "agent_reference";


ALTER SCHEMA "agent_reference" OWNER TO "postgres";


COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE EXTENSION IF NOT EXISTS "pg_graphql" WITH SCHEMA "graphql";






CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pg_trgm" WITH SCHEMA "public";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "unaccent" WITH SCHEMA "public";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "vector" WITH SCHEMA "public";






CREATE OR REPLACE FUNCTION "agent_reference"."search_authors"("search_term" "text") RETURNS TABLE("author_id" "text", "full_name" "text", "first_name" "text", "first_last_name" "text", "second_last_name" "text", "pseudonym" "text", "similarity_score" real)
    LANGUAGE "plpgsql"
    AS $$
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
$$;


ALTER FUNCTION "agent_reference"."search_authors"("search_term" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "agent_reference"."search_works"("search_term" "text") RETURNS TABLE("legacy_identifier" "text", "title" "text", "authors_jsonb" "jsonb", "similarity_score" real)
    LANGUAGE "plpgsql"
    AS $$
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
$$;


ALTER FUNCTION "agent_reference"."search_works"("search_term" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "agent_reference"."update_search_fields"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
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
$$;


ALTER FUNCTION "agent_reference"."update_search_fields"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."documents_v2_fill_from_metadata"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
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
$$;


ALTER FUNCTION "public"."documents_v2_fill_from_metadata"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."documents_v2_fts_refresh"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  new.fts_en := to_tsvector('english', unaccent(coalesce(new.content,'')));
  new.fts_es := to_tsvector('spanish', unaccent(coalesce(new.content,'')));
  return new;
end;
$$;


ALTER FUNCTION "public"."documents_v2_fts_refresh"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."hybrid_search_v2"("query_text" "text", "query_embedding" "public"."vector", "match_count" integer DEFAULT 5, "filter" "jsonb" DEFAULT '{}'::"jsonb", "lang" "text" DEFAULT 'auto'::"text", "full_text_weight" double precision DEFAULT 1.5, "semantic_weight" double precision DEFAULT 2.0, "rrf_k" integer DEFAULT 50) RETURNS TABLE("id" "uuid", "content" "text", "metadata" "jsonb", "file_name" "text", "lang" "text", "embedding" "public"."vector", "fts_en" "tsvector", "fts_es" "tsvector", "vector_score" double precision, "keyword_score" double precision, "vector_rank" bigint, "keyword_rank" bigint, "final_score" double precision)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    AS $$
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
$$;


ALTER FUNCTION "public"."hybrid_search_v2"("query_text" "text", "query_embedding" "public"."vector", "match_count" integer, "filter" "jsonb", "lang" "text", "full_text_weight" double precision, "semantic_weight" double precision, "rrf_k" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."hybrid_search_v2_with_details"("p_query_text" "text", "p_query_embedding" "public"."vector", "p_match_count" integer, "p_filter" "jsonb", "p_lang" "text", "p_full_text_weight" double precision, "p_semantic_weight" double precision, "p_rrf_k" integer) RETURNS TABLE("id" "uuid", "content" "text", "metadata" "jsonb", "file_name" "text", "doc_lang" "text", "vector_score" double precision, "keyword_score" double precision, "vector_rank" integer, "keyword_rank" integer, "final_score" double precision)
    LANGUAGE "plpgsql"
    AS $$
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
$$;


ALTER FUNCTION "public"."hybrid_search_v2_with_details"("p_query_text" "text", "p_query_embedding" "public"."vector", "p_match_count" integer, "p_filter" "jsonb", "p_lang" "text", "p_full_text_weight" double precision, "p_semantic_weight" double precision, "p_rrf_k" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."hybrid_search_v2_with_details_debug"("p_query_text" "text", "p_query_embedding" "public"."vector", "p_match_count" integer, "p_filter" "jsonb", "p_lang" "text", "p_full_text_weight" double precision, "p_semantic_weight" double precision, "p_rrf_k" integer) RETURNS TABLE("id" "uuid", "content" "text", "metadata" "jsonb", "file_name" "text", "doc_lang" "text", "vector_score" double precision, "keyword_score" double precision, "vector_rank" integer, "keyword_rank" integer, "final_score" double precision, "q_es" "text", "q_en" "text", "r_es" double precision, "r_en" double precision, "used_lang" "text", "used_tsquery" "text")
    LANGUAGE "plpgsql"
    AS $$
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
$$;


ALTER FUNCTION "public"."hybrid_search_v2_with_details_debug"("p_query_text" "text", "p_query_embedding" "public"."vector", "p_match_count" integer, "p_filter" "jsonb", "p_lang" "text", "p_full_text_weight" double precision, "p_semantic_weight" double precision, "p_rrf_k" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."match_documents"("query_embedding" "public"."vector", "match_count" integer DEFAULT NULL::integer, "filter" "jsonb" DEFAULT '{}'::"jsonb") RETURNS TABLE("id" bigint, "content" "text", "metadata" "jsonb", "similarity" double precision)
    LANGUAGE "plpgsql"
    AS $$begin
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
end;$$;


ALTER FUNCTION "public"."match_documents"("query_embedding" "public"."vector", "match_count" integer, "filter" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_lang_from_metadata"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  -- If metadata has a lang field, use it
  if NEW.metadata ? 'lang' then
    NEW.lang := NEW.metadata->>'lang';
  end if;
  return NEW;
end;
$$;


ALTER FUNCTION "public"."set_lang_from_metadata"() OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "agent_reference"."authors_ref" (
    "author_id" "text" NOT NULL,
    "full_name" "text",
    "first_name" "text",
    "first_last_name" "text",
    "second_last_name" "text",
    "pseudonym" "text",
    "normalized_name" "text",
    "search_vector" "tsvector",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "agent_reference"."authors_ref" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "agent_reference"."liberation_reference" (
    "legacy_identifier" bigint,
    "version" "text",
    "title" "text",
    "publisher" "text",
    "catalog" "text",
    "mexico" "text",
    "usa_canada" "text",
    "latam" "text",
    "sapan_portugal" "text",
    "brazil" "text",
    "rest_of_world" "text"
);


ALTER TABLE "agent_reference"."liberation_reference" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "agent_reference"."lookup_values" (
    "id" integer NOT NULL,
    "category" "text" NOT NULL,
    "value" "text" NOT NULL,
    "group_name" "text",
    "sort_order" integer DEFAULT 0,
    "active" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "agent_reference"."lookup_values" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "agent_reference"."lookup_values_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "agent_reference"."lookup_values_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "agent_reference"."lookup_values_id_seq" OWNED BY "agent_reference"."lookup_values"."id";



CREATE OR REPLACE VIEW "agent_reference"."source_groups" AS
 SELECT "group_name",
    "array_agg"("value" ORDER BY "sort_order") AS "sources"
   FROM "agent_reference"."lookup_values"
  WHERE (("category" = 'source'::"text") AND ("group_name" IS NOT NULL))
  GROUP BY "group_name";


ALTER VIEW "agent_reference"."source_groups" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "agent_reference"."works_ref" (
    "legacy_identifier" "text" NOT NULL,
    "title" "text",
    "authors" json,
    "normalized_title" "text",
    "authors_jsonb" "jsonb",
    "search_vector" "tsvector",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "mexico" "text",
    "usa" "text",
    "latam" "text",
    "spain_portugal" "text",
    "brazil" "text",
    "rest_of_world" "text"
);


ALTER TABLE "agent_reference"."works_ref" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."documents" (
    "id" bigint NOT NULL,
    "content" "text",
    "metadata" "jsonb",
    "embedding" "public"."vector"(1536)
);


ALTER TABLE "public"."documents" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."documents_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."documents_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."documents_id_seq" OWNED BY "public"."documents"."id";



CREATE TABLE IF NOT EXISTS "public"."documents_v2" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "content" "text" NOT NULL,
    "metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "lang" "text" NOT NULL,
    "embedding" "public"."vector"(1536),
    "fts_en" "tsvector",
    "fts_es" "tsvector",
    "file_name" "text",
    CONSTRAINT "documents_v2_lang_check" CHECK (("lang" = ANY (ARRAY['en'::"text", 'es'::"text"])))
);


ALTER TABLE "public"."documents_v2" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."record_manager" (
    "id" bigint NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "google_drive_file_id" "text" NOT NULL,
    "hash" "text" NOT NULL,
    "file_name" "text"
);


ALTER TABLE "public"."record_manager" OWNER TO "postgres";


ALTER TABLE "public"."record_manager" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."record_manager_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."record_manager_v2" (
    "id" bigint NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "google_drive_file_id" "text" NOT NULL,
    "hash" "text" NOT NULL,
    "file_name" "text"
);


ALTER TABLE "public"."record_manager_v2" OWNER TO "postgres";


ALTER TABLE "public"."record_manager_v2" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."record_manager_v2_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



ALTER TABLE ONLY "agent_reference"."lookup_values" ALTER COLUMN "id" SET DEFAULT "nextval"('"agent_reference"."lookup_values_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."documents" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."documents_id_seq"'::"regclass");



ALTER TABLE ONLY "agent_reference"."authors_ref"
    ADD CONSTRAINT "authors_ref_pkey" PRIMARY KEY ("author_id");



ALTER TABLE ONLY "agent_reference"."lookup_values"
    ADD CONSTRAINT "lookup_values_category_value_key" UNIQUE ("category", "value");



ALTER TABLE ONLY "agent_reference"."lookup_values"
    ADD CONSTRAINT "lookup_values_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."documents"
    ADD CONSTRAINT "documents_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."documents_v2"
    ADD CONSTRAINT "documents_v2_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."record_manager"
    ADD CONSTRAINT "record_manager_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."record_manager_v2"
    ADD CONSTRAINT "record_manager_v2_pkey" PRIMARY KEY ("id");



CREATE INDEX "idx_authors_normalized_name" ON "agent_reference"."authors_ref" USING "gin" ("normalized_name" "public"."gin_trgm_ops");



CREATE INDEX "idx_authors_pseudonym" ON "agent_reference"."authors_ref" USING "btree" ("pseudonym") WHERE ("pseudonym" IS NOT NULL);



CREATE INDEX "idx_authors_search_vector" ON "agent_reference"."authors_ref" USING "gin" ("search_vector");



CREATE INDEX "idx_lookup_category" ON "agent_reference"."lookup_values" USING "btree" ("category");



CREATE INDEX "idx_lookup_group" ON "agent_reference"."lookup_values" USING "btree" ("group_name") WHERE ("group_name" IS NOT NULL);



CREATE INDEX "idx_works_authors_jsonb" ON "agent_reference"."works_ref" USING "gin" ("authors_jsonb");



CREATE INDEX "idx_works_normalized_title" ON "agent_reference"."works_ref" USING "gin" ("normalized_title" "public"."gin_trgm_ops");



CREATE INDEX "idx_works_search_vector" ON "agent_reference"."works_ref" USING "gin" ("search_vector");



CREATE INDEX "documents_v2_embedding_hnsw" ON "public"."documents_v2" USING "hnsw" ("embedding" "public"."vector_cosine_ops");



CREATE INDEX "documents_v2_fts_en_gin" ON "public"."documents_v2" USING "gin" ("fts_en");



CREATE INDEX "documents_v2_fts_es_gin" ON "public"."documents_v2" USING "gin" ("fts_es");



CREATE INDEX "documents_v2_meta_category_gin" ON "public"."documents_v2" USING "gin" ((("metadata" -> 'category'::"text")));



CREATE INDEX "documents_v2_meta_filename_trgm" ON "public"."documents_v2" USING "gin" ((("metadata" ->> 'file_name'::"text")) "public"."gin_trgm_ops");



CREATE INDEX "idx_documents_v2_file_name_ci" ON "public"."documents_v2" USING "btree" ("lower"("file_name"));



CREATE INDEX "idx_documents_v2_file_name_trgm" ON "public"."documents_v2" USING "gin" ("lower"("file_name") "public"."gin_trgm_ops");



CREATE OR REPLACE TRIGGER "trigger_authors_search_fields" BEFORE INSERT OR UPDATE ON "agent_reference"."authors_ref" FOR EACH ROW EXECUTE FUNCTION "agent_reference"."update_search_fields"();



CREATE OR REPLACE TRIGGER "trigger_works_search_fields" BEFORE INSERT OR UPDATE ON "agent_reference"."works_ref" FOR EACH ROW EXECUTE FUNCTION "agent_reference"."update_search_fields"();



CREATE OR REPLACE TRIGGER "documents_v2_fts_refresh_ins" BEFORE INSERT ON "public"."documents_v2" FOR EACH ROW EXECUTE FUNCTION "public"."documents_v2_fts_refresh"();



CREATE OR REPLACE TRIGGER "documents_v2_fts_refresh_upd" BEFORE UPDATE OF "content" ON "public"."documents_v2" FOR EACH ROW EXECUTE FUNCTION "public"."documents_v2_fts_refresh"();



CREATE OR REPLACE TRIGGER "trg_documents_v2_fill_from_metadata" BEFORE INSERT OR UPDATE ON "public"."documents_v2" FOR EACH ROW EXECUTE FUNCTION "public"."documents_v2_fill_from_metadata"();



CREATE OR REPLACE TRIGGER "trg_set_lang_from_metadata" BEFORE INSERT OR UPDATE ON "public"."documents_v2" FOR EACH ROW EXECUTE FUNCTION "public"."set_lang_from_metadata"();



CREATE POLICY "Enable read access for all users" ON "agent_reference"."authors_ref" FOR SELECT USING (true);



CREATE POLICY "Enable read access for all users" ON "agent_reference"."lookup_values" FOR SELECT USING (true);



CREATE POLICY "Enable read access for all users" ON "agent_reference"."works_ref" FOR SELECT USING (true);



ALTER TABLE "agent_reference"."authors_ref" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "agent_reference"."liberation_reference" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "agent_reference"."lookup_values" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "agent_reference"."works_ref" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."documents" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."record_manager" ENABLE ROW LEVEL SECURITY;




ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";


GRANT USAGE ON SCHEMA "agent_reference" TO "authenticator";
GRANT USAGE ON SCHEMA "agent_reference" TO "anon";
GRANT USAGE ON SCHEMA "agent_reference" TO "authenticated";
GRANT USAGE ON SCHEMA "agent_reference" TO "service_role";



GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_in"("cstring") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_in"("cstring") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_in"("cstring") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_in"("cstring") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_out"("public"."gtrgm") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_out"("public"."gtrgm") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_out"("public"."gtrgm") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_out"("public"."gtrgm") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_in"("cstring", "oid", integer) TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_in"("cstring", "oid", integer) TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_in"("cstring", "oid", integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_in"("cstring", "oid", integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_out"("public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_out"("public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_out"("public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_out"("public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_recv"("internal", "oid", integer) TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_recv"("internal", "oid", integer) TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_recv"("internal", "oid", integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_recv"("internal", "oid", integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_send"("public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_send"("public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_send"("public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_send"("public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_typmod_in"("cstring"[]) TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_typmod_in"("cstring"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_typmod_in"("cstring"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_typmod_in"("cstring"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_in"("cstring", "oid", integer) TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_in"("cstring", "oid", integer) TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_in"("cstring", "oid", integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_in"("cstring", "oid", integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_out"("public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_out"("public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_out"("public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_out"("public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_recv"("internal", "oid", integer) TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_recv"("internal", "oid", integer) TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_recv"("internal", "oid", integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_recv"("internal", "oid", integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_send"("public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_send"("public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_send"("public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_send"("public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_typmod_in"("cstring"[]) TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_typmod_in"("cstring"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_typmod_in"("cstring"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_typmod_in"("cstring"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_in"("cstring", "oid", integer) TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_in"("cstring", "oid", integer) TO "anon";
GRANT ALL ON FUNCTION "public"."vector_in"("cstring", "oid", integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_in"("cstring", "oid", integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_out"("public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_out"("public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_out"("public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_out"("public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_recv"("internal", "oid", integer) TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_recv"("internal", "oid", integer) TO "anon";
GRANT ALL ON FUNCTION "public"."vector_recv"("internal", "oid", integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_recv"("internal", "oid", integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_send"("public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_send"("public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_send"("public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_send"("public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_typmod_in"("cstring"[]) TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_typmod_in"("cstring"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."vector_typmod_in"("cstring"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_typmod_in"("cstring"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_halfvec"(real[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(real[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(real[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(real[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(real[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(real[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(real[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(real[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_vector"(real[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_vector"(real[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_vector"(real[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_vector"(real[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_halfvec"(double precision[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(double precision[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(double precision[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(double precision[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(double precision[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(double precision[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(double precision[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(double precision[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_vector"(double precision[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_vector"(double precision[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_vector"(double precision[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_vector"(double precision[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_halfvec"(integer[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(integer[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(integer[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(integer[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(integer[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(integer[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(integer[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(integer[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_vector"(integer[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_vector"(integer[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_vector"(integer[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_vector"(integer[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_halfvec"(numeric[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(numeric[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(numeric[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_halfvec"(numeric[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(numeric[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(numeric[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(numeric[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_sparsevec"(numeric[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."array_to_vector"(numeric[], integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."array_to_vector"(numeric[], integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."array_to_vector"(numeric[], integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."array_to_vector"(numeric[], integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_to_float4"("public"."halfvec", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_to_float4"("public"."halfvec", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_to_float4"("public"."halfvec", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_to_float4"("public"."halfvec", integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec"("public"."halfvec", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec"("public"."halfvec", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec"("public"."halfvec", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec"("public"."halfvec", integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_to_sparsevec"("public"."halfvec", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_to_sparsevec"("public"."halfvec", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_to_sparsevec"("public"."halfvec", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_to_sparsevec"("public"."halfvec", integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_to_vector"("public"."halfvec", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_to_vector"("public"."halfvec", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_to_vector"("public"."halfvec", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_to_vector"("public"."halfvec", integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_to_halfvec"("public"."sparsevec", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_to_halfvec"("public"."sparsevec", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_to_halfvec"("public"."sparsevec", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_to_halfvec"("public"."sparsevec", integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec"("public"."sparsevec", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec"("public"."sparsevec", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec"("public"."sparsevec", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec"("public"."sparsevec", integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_to_vector"("public"."sparsevec", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_to_vector"("public"."sparsevec", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_to_vector"("public"."sparsevec", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_to_vector"("public"."sparsevec", integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_to_float4"("public"."vector", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_to_float4"("public"."vector", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."vector_to_float4"("public"."vector", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_to_float4"("public"."vector", integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_to_halfvec"("public"."vector", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_to_halfvec"("public"."vector", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."vector_to_halfvec"("public"."vector", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_to_halfvec"("public"."vector", integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_to_sparsevec"("public"."vector", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_to_sparsevec"("public"."vector", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."vector_to_sparsevec"("public"."vector", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_to_sparsevec"("public"."vector", integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."vector"("public"."vector", integer, boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."vector"("public"."vector", integer, boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."vector"("public"."vector", integer, boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector"("public"."vector", integer, boolean) TO "service_role";



GRANT ALL ON FUNCTION "agent_reference"."search_authors"("search_term" "text") TO "anon";
GRANT ALL ON FUNCTION "agent_reference"."search_authors"("search_term" "text") TO "authenticated";
GRANT ALL ON FUNCTION "agent_reference"."search_authors"("search_term" "text") TO "service_role";
GRANT ALL ON FUNCTION "agent_reference"."search_authors"("search_term" "text") TO "authenticator";



GRANT ALL ON FUNCTION "agent_reference"."search_works"("search_term" "text") TO "anon";
GRANT ALL ON FUNCTION "agent_reference"."search_works"("search_term" "text") TO "authenticated";
GRANT ALL ON FUNCTION "agent_reference"."search_works"("search_term" "text") TO "service_role";
GRANT ALL ON FUNCTION "agent_reference"."search_works"("search_term" "text") TO "authenticator";



GRANT ALL ON FUNCTION "agent_reference"."update_search_fields"() TO "anon";
GRANT ALL ON FUNCTION "agent_reference"."update_search_fields"() TO "authenticated";
GRANT ALL ON FUNCTION "agent_reference"."update_search_fields"() TO "service_role";
GRANT ALL ON FUNCTION "agent_reference"."update_search_fields"() TO "authenticator";

























































































































































GRANT ALL ON FUNCTION "public"."binary_quantize"("public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."binary_quantize"("public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."binary_quantize"("public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."binary_quantize"("public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."binary_quantize"("public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."binary_quantize"("public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."binary_quantize"("public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."binary_quantize"("public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."cosine_distance"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."documents_v2_fill_from_metadata"() TO "anon";
GRANT ALL ON FUNCTION "public"."documents_v2_fill_from_metadata"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."documents_v2_fill_from_metadata"() TO "service_role";



GRANT ALL ON FUNCTION "public"."documents_v2_fts_refresh"() TO "anon";
GRANT ALL ON FUNCTION "public"."documents_v2_fts_refresh"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."documents_v2_fts_refresh"() TO "service_role";



GRANT ALL ON FUNCTION "public"."gin_extract_query_trgm"("text", "internal", smallint, "internal", "internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gin_extract_query_trgm"("text", "internal", smallint, "internal", "internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gin_extract_query_trgm"("text", "internal", smallint, "internal", "internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gin_extract_query_trgm"("text", "internal", smallint, "internal", "internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gin_extract_value_trgm"("text", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gin_extract_value_trgm"("text", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gin_extract_value_trgm"("text", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gin_extract_value_trgm"("text", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gin_trgm_consistent"("internal", smallint, "text", integer, "internal", "internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gin_trgm_consistent"("internal", smallint, "text", integer, "internal", "internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gin_trgm_consistent"("internal", smallint, "text", integer, "internal", "internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gin_trgm_consistent"("internal", smallint, "text", integer, "internal", "internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gin_trgm_triconsistent"("internal", smallint, "text", integer, "internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gin_trgm_triconsistent"("internal", smallint, "text", integer, "internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gin_trgm_triconsistent"("internal", smallint, "text", integer, "internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gin_trgm_triconsistent"("internal", smallint, "text", integer, "internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_consistent"("internal", "text", smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_consistent"("internal", "text", smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_consistent"("internal", "text", smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_consistent"("internal", "text", smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_decompress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_decompress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_decompress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_decompress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_distance"("internal", "text", smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_distance"("internal", "text", smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_distance"("internal", "text", smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_distance"("internal", "text", smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_options"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_options"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_options"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_options"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_same"("public"."gtrgm", "public"."gtrgm", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_same"("public"."gtrgm", "public"."gtrgm", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_same"("public"."gtrgm", "public"."gtrgm", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_same"("public"."gtrgm", "public"."gtrgm", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_accum"(double precision[], "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_accum"(double precision[], "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_accum"(double precision[], "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_accum"(double precision[], "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_add"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_add"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_add"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_add"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_avg"(double precision[]) TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_avg"(double precision[]) TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_avg"(double precision[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_avg"(double precision[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_cmp"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_cmp"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_cmp"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_cmp"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_combine"(double precision[], double precision[]) TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_combine"(double precision[], double precision[]) TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_combine"(double precision[], double precision[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_combine"(double precision[], double precision[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_concat"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_concat"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_concat"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_concat"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_eq"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_eq"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_eq"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_eq"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_ge"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_ge"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_ge"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_ge"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_gt"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_gt"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_gt"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_gt"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_l2_squared_distance"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_l2_squared_distance"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_l2_squared_distance"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_l2_squared_distance"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_le"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_le"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_le"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_le"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_lt"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_lt"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_lt"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_lt"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_mul"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_mul"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_mul"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_mul"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_ne"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_ne"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_ne"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_ne"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_negative_inner_product"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_negative_inner_product"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_negative_inner_product"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_negative_inner_product"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_spherical_distance"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_spherical_distance"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_spherical_distance"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_spherical_distance"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."halfvec_sub"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."halfvec_sub"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."halfvec_sub"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."halfvec_sub"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."hamming_distance"(bit, bit) TO "postgres";
GRANT ALL ON FUNCTION "public"."hamming_distance"(bit, bit) TO "anon";
GRANT ALL ON FUNCTION "public"."hamming_distance"(bit, bit) TO "authenticated";
GRANT ALL ON FUNCTION "public"."hamming_distance"(bit, bit) TO "service_role";



GRANT ALL ON FUNCTION "public"."hnsw_bit_support"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."hnsw_bit_support"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."hnsw_bit_support"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."hnsw_bit_support"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."hnsw_halfvec_support"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."hnsw_halfvec_support"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."hnsw_halfvec_support"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."hnsw_halfvec_support"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."hnsw_sparsevec_support"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."hnsw_sparsevec_support"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."hnsw_sparsevec_support"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."hnsw_sparsevec_support"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."hnswhandler"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."hnswhandler"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."hnswhandler"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."hnswhandler"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."hybrid_search_v2"("query_text" "text", "query_embedding" "public"."vector", "match_count" integer, "filter" "jsonb", "lang" "text", "full_text_weight" double precision, "semantic_weight" double precision, "rrf_k" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."hybrid_search_v2"("query_text" "text", "query_embedding" "public"."vector", "match_count" integer, "filter" "jsonb", "lang" "text", "full_text_weight" double precision, "semantic_weight" double precision, "rrf_k" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."hybrid_search_v2"("query_text" "text", "query_embedding" "public"."vector", "match_count" integer, "filter" "jsonb", "lang" "text", "full_text_weight" double precision, "semantic_weight" double precision, "rrf_k" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."hybrid_search_v2_with_details"("p_query_text" "text", "p_query_embedding" "public"."vector", "p_match_count" integer, "p_filter" "jsonb", "p_lang" "text", "p_full_text_weight" double precision, "p_semantic_weight" double precision, "p_rrf_k" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."hybrid_search_v2_with_details"("p_query_text" "text", "p_query_embedding" "public"."vector", "p_match_count" integer, "p_filter" "jsonb", "p_lang" "text", "p_full_text_weight" double precision, "p_semantic_weight" double precision, "p_rrf_k" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."hybrid_search_v2_with_details"("p_query_text" "text", "p_query_embedding" "public"."vector", "p_match_count" integer, "p_filter" "jsonb", "p_lang" "text", "p_full_text_weight" double precision, "p_semantic_weight" double precision, "p_rrf_k" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."hybrid_search_v2_with_details_debug"("p_query_text" "text", "p_query_embedding" "public"."vector", "p_match_count" integer, "p_filter" "jsonb", "p_lang" "text", "p_full_text_weight" double precision, "p_semantic_weight" double precision, "p_rrf_k" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."hybrid_search_v2_with_details_debug"("p_query_text" "text", "p_query_embedding" "public"."vector", "p_match_count" integer, "p_filter" "jsonb", "p_lang" "text", "p_full_text_weight" double precision, "p_semantic_weight" double precision, "p_rrf_k" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."hybrid_search_v2_with_details_debug"("p_query_text" "text", "p_query_embedding" "public"."vector", "p_match_count" integer, "p_filter" "jsonb", "p_lang" "text", "p_full_text_weight" double precision, "p_semantic_weight" double precision, "p_rrf_k" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."inner_product"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."inner_product"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."inner_product"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."inner_product"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."inner_product"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."inner_product"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."inner_product"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."inner_product"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."inner_product"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."inner_product"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."inner_product"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."inner_product"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."ivfflat_bit_support"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."ivfflat_bit_support"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."ivfflat_bit_support"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."ivfflat_bit_support"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."ivfflat_halfvec_support"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."ivfflat_halfvec_support"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."ivfflat_halfvec_support"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."ivfflat_halfvec_support"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."ivfflathandler"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."ivfflathandler"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."ivfflathandler"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."ivfflathandler"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."jaccard_distance"(bit, bit) TO "postgres";
GRANT ALL ON FUNCTION "public"."jaccard_distance"(bit, bit) TO "anon";
GRANT ALL ON FUNCTION "public"."jaccard_distance"(bit, bit) TO "authenticated";
GRANT ALL ON FUNCTION "public"."jaccard_distance"(bit, bit) TO "service_role";



GRANT ALL ON FUNCTION "public"."l1_distance"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."l1_distance"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."l1_distance"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l1_distance"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."l1_distance"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."l1_distance"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."l1_distance"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l1_distance"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."l1_distance"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."l1_distance"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."l1_distance"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l1_distance"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."l2_distance"("public"."halfvec", "public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."l2_distance"("public"."halfvec", "public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."l2_distance"("public"."halfvec", "public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l2_distance"("public"."halfvec", "public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."l2_distance"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."l2_distance"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."l2_distance"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l2_distance"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."l2_distance"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."l2_distance"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."l2_distance"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l2_distance"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."l2_norm"("public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."l2_norm"("public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."l2_norm"("public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l2_norm"("public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."l2_norm"("public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."l2_norm"("public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."l2_norm"("public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l2_norm"("public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."l2_normalize"("public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."match_documents"("query_embedding" "public"."vector", "match_count" integer, "filter" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."match_documents"("query_embedding" "public"."vector", "match_count" integer, "filter" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."match_documents"("query_embedding" "public"."vector", "match_count" integer, "filter" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."set_lang_from_metadata"() TO "anon";
GRANT ALL ON FUNCTION "public"."set_lang_from_metadata"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_lang_from_metadata"() TO "service_role";



GRANT ALL ON FUNCTION "public"."set_limit"(real) TO "postgres";
GRANT ALL ON FUNCTION "public"."set_limit"(real) TO "anon";
GRANT ALL ON FUNCTION "public"."set_limit"(real) TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_limit"(real) TO "service_role";



GRANT ALL ON FUNCTION "public"."show_limit"() TO "postgres";
GRANT ALL ON FUNCTION "public"."show_limit"() TO "anon";
GRANT ALL ON FUNCTION "public"."show_limit"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."show_limit"() TO "service_role";



GRANT ALL ON FUNCTION "public"."show_trgm"("text") TO "postgres";
GRANT ALL ON FUNCTION "public"."show_trgm"("text") TO "anon";
GRANT ALL ON FUNCTION "public"."show_trgm"("text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."show_trgm"("text") TO "service_role";



GRANT ALL ON FUNCTION "public"."similarity"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."similarity"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."similarity"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."similarity"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."similarity_dist"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."similarity_dist"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."similarity_dist"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."similarity_dist"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."similarity_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."similarity_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."similarity_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."similarity_op"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_cmp"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_cmp"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_cmp"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_cmp"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_eq"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_eq"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_eq"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_eq"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_ge"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_ge"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_ge"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_ge"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_gt"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_gt"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_gt"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_gt"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_l2_squared_distance"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_l2_squared_distance"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_l2_squared_distance"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_l2_squared_distance"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_le"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_le"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_le"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_le"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_lt"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_lt"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_lt"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_lt"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_ne"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_ne"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_ne"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_ne"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sparsevec_negative_inner_product"("public"."sparsevec", "public"."sparsevec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sparsevec_negative_inner_product"("public"."sparsevec", "public"."sparsevec") TO "anon";
GRANT ALL ON FUNCTION "public"."sparsevec_negative_inner_product"("public"."sparsevec", "public"."sparsevec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sparsevec_negative_inner_product"("public"."sparsevec", "public"."sparsevec") TO "service_role";



GRANT ALL ON FUNCTION "public"."strict_word_similarity"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."strict_word_similarity"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."strict_word_similarity"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."strict_word_similarity"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."strict_word_similarity_commutator_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_commutator_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_commutator_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_commutator_op"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_commutator_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_commutator_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_commutator_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_commutator_op"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_op"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."strict_word_similarity_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_op"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."subvector"("public"."halfvec", integer, integer) TO "postgres";
GRANT ALL ON FUNCTION "public"."subvector"("public"."halfvec", integer, integer) TO "anon";
GRANT ALL ON FUNCTION "public"."subvector"("public"."halfvec", integer, integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."subvector"("public"."halfvec", integer, integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."subvector"("public"."vector", integer, integer) TO "postgres";
GRANT ALL ON FUNCTION "public"."subvector"("public"."vector", integer, integer) TO "anon";
GRANT ALL ON FUNCTION "public"."subvector"("public"."vector", integer, integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."subvector"("public"."vector", integer, integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."unaccent"("text") TO "postgres";
GRANT ALL ON FUNCTION "public"."unaccent"("text") TO "anon";
GRANT ALL ON FUNCTION "public"."unaccent"("text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."unaccent"("text") TO "service_role";



GRANT ALL ON FUNCTION "public"."unaccent"("regdictionary", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."unaccent"("regdictionary", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."unaccent"("regdictionary", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."unaccent"("regdictionary", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."unaccent_init"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."unaccent_init"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."unaccent_init"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."unaccent_init"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."unaccent_lexize"("internal", "internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."unaccent_lexize"("internal", "internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."unaccent_lexize"("internal", "internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."unaccent_lexize"("internal", "internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_accum"(double precision[], "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_accum"(double precision[], "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_accum"(double precision[], "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_accum"(double precision[], "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_add"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_add"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_add"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_add"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_avg"(double precision[]) TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_avg"(double precision[]) TO "anon";
GRANT ALL ON FUNCTION "public"."vector_avg"(double precision[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_avg"(double precision[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_cmp"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_cmp"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_cmp"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_cmp"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_combine"(double precision[], double precision[]) TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_combine"(double precision[], double precision[]) TO "anon";
GRANT ALL ON FUNCTION "public"."vector_combine"(double precision[], double precision[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_combine"(double precision[], double precision[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_concat"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_concat"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_concat"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_concat"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_dims"("public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_dims"("public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_dims"("public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_dims"("public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_dims"("public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_dims"("public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_dims"("public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_dims"("public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_eq"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_eq"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_eq"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_eq"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_ge"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_ge"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_ge"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_ge"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_gt"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_gt"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_gt"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_gt"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_l2_squared_distance"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_l2_squared_distance"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_l2_squared_distance"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_l2_squared_distance"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_le"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_le"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_le"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_le"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_lt"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_lt"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_lt"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_lt"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_mul"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_mul"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_mul"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_mul"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_ne"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_ne"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_ne"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_ne"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_negative_inner_product"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_negative_inner_product"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_negative_inner_product"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_negative_inner_product"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_norm"("public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_norm"("public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_norm"("public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_norm"("public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_spherical_distance"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_spherical_distance"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_spherical_distance"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_spherical_distance"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."vector_sub"("public"."vector", "public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."vector_sub"("public"."vector", "public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."vector_sub"("public"."vector", "public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vector_sub"("public"."vector", "public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."word_similarity"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."word_similarity"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."word_similarity"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."word_similarity"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."word_similarity_commutator_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."word_similarity_commutator_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."word_similarity_commutator_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."word_similarity_commutator_op"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."word_similarity_dist_commutator_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."word_similarity_dist_commutator_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."word_similarity_dist_commutator_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."word_similarity_dist_commutator_op"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."word_similarity_dist_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."word_similarity_dist_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."word_similarity_dist_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."word_similarity_dist_op"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."word_similarity_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."word_similarity_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."word_similarity_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."word_similarity_op"("text", "text") TO "service_role";












GRANT ALL ON FUNCTION "public"."avg"("public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."avg"("public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."avg"("public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."avg"("public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."avg"("public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."avg"("public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."avg"("public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."avg"("public"."vector") TO "service_role";



GRANT ALL ON FUNCTION "public"."sum"("public"."halfvec") TO "postgres";
GRANT ALL ON FUNCTION "public"."sum"("public"."halfvec") TO "anon";
GRANT ALL ON FUNCTION "public"."sum"("public"."halfvec") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sum"("public"."halfvec") TO "service_role";



GRANT ALL ON FUNCTION "public"."sum"("public"."vector") TO "postgres";
GRANT ALL ON FUNCTION "public"."sum"("public"."vector") TO "anon";
GRANT ALL ON FUNCTION "public"."sum"("public"."vector") TO "authenticated";
GRANT ALL ON FUNCTION "public"."sum"("public"."vector") TO "service_role";



GRANT ALL ON TABLE "agent_reference"."authors_ref" TO "anon";
GRANT ALL ON TABLE "agent_reference"."authors_ref" TO "authenticated";
GRANT ALL ON TABLE "agent_reference"."authors_ref" TO "authenticator";
GRANT ALL ON TABLE "agent_reference"."authors_ref" TO "service_role";



GRANT ALL ON TABLE "agent_reference"."liberation_reference" TO "anon";
GRANT ALL ON TABLE "agent_reference"."liberation_reference" TO "authenticated";
GRANT ALL ON TABLE "agent_reference"."liberation_reference" TO "service_role";
GRANT ALL ON TABLE "agent_reference"."liberation_reference" TO "authenticator";



GRANT ALL ON TABLE "agent_reference"."lookup_values" TO "anon";
GRANT ALL ON TABLE "agent_reference"."lookup_values" TO "authenticated";
GRANT ALL ON TABLE "agent_reference"."lookup_values" TO "authenticator";
GRANT ALL ON TABLE "agent_reference"."lookup_values" TO "service_role";



GRANT ALL ON SEQUENCE "agent_reference"."lookup_values_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "agent_reference"."lookup_values_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "agent_reference"."lookup_values_id_seq" TO "service_role";
GRANT ALL ON SEQUENCE "agent_reference"."lookup_values_id_seq" TO "authenticator";



GRANT ALL ON TABLE "agent_reference"."source_groups" TO "anon";
GRANT ALL ON TABLE "agent_reference"."source_groups" TO "authenticated";
GRANT ALL ON TABLE "agent_reference"."source_groups" TO "authenticator";
GRANT ALL ON TABLE "agent_reference"."source_groups" TO "service_role";



GRANT ALL ON TABLE "agent_reference"."works_ref" TO "anon";
GRANT ALL ON TABLE "agent_reference"."works_ref" TO "authenticated";
GRANT ALL ON TABLE "agent_reference"."works_ref" TO "authenticator";
GRANT ALL ON TABLE "agent_reference"."works_ref" TO "service_role";









GRANT ALL ON TABLE "public"."documents" TO "anon";
GRANT ALL ON TABLE "public"."documents" TO "authenticated";
GRANT ALL ON TABLE "public"."documents" TO "service_role";



GRANT ALL ON SEQUENCE "public"."documents_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."documents_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."documents_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."documents_v2" TO "anon";
GRANT ALL ON TABLE "public"."documents_v2" TO "authenticated";
GRANT ALL ON TABLE "public"."documents_v2" TO "service_role";



GRANT ALL ON TABLE "public"."record_manager" TO "anon";
GRANT ALL ON TABLE "public"."record_manager" TO "authenticated";
GRANT ALL ON TABLE "public"."record_manager" TO "service_role";



GRANT ALL ON SEQUENCE "public"."record_manager_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."record_manager_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."record_manager_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."record_manager_v2" TO "anon";
GRANT ALL ON TABLE "public"."record_manager_v2" TO "authenticated";
GRANT ALL ON TABLE "public"."record_manager_v2" TO "service_role";



GRANT ALL ON SEQUENCE "public"."record_manager_v2_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."record_manager_v2_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."record_manager_v2_id_seq" TO "service_role";









ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "agent_reference" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "agent_reference" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "agent_reference" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "agent_reference" GRANT ALL ON SEQUENCES TO "service_role";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "agent_reference" GRANT ALL ON SEQUENCES TO "authenticator";



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "agent_reference" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "agent_reference" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "agent_reference" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "agent_reference" GRANT ALL ON FUNCTIONS TO "service_role";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "agent_reference" GRANT ALL ON FUNCTIONS TO "authenticator";



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "agent_reference" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "agent_reference" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "agent_reference" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "agent_reference" GRANT ALL ON TABLES TO "service_role";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "agent_reference" GRANT ALL ON TABLES TO "authenticator";



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";






























RESET ALL;
