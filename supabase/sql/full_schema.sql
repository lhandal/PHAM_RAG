

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


CREATE SCHEMA IF NOT EXISTS "public";


ALTER SCHEMA "public" OWNER TO "pg_database_owner";


COMMENT ON SCHEMA "public" IS 'standard public schema';



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



ALTER TABLE ONLY "public"."documents" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."documents_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."documents"
    ADD CONSTRAINT "documents_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."documents_v2"
    ADD CONSTRAINT "documents_v2_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."record_manager"
    ADD CONSTRAINT "record_manager_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."record_manager_v2"
    ADD CONSTRAINT "record_manager_v2_pkey" PRIMARY KEY ("id");



CREATE INDEX "documents_v2_embedding_hnsw" ON "public"."documents_v2" USING "hnsw" ("embedding" "public"."vector_cosine_ops");



CREATE INDEX "documents_v2_fts_en_gin" ON "public"."documents_v2" USING "gin" ("fts_en");



CREATE INDEX "documents_v2_fts_es_gin" ON "public"."documents_v2" USING "gin" ("fts_es");



CREATE INDEX "documents_v2_meta_category_gin" ON "public"."documents_v2" USING "gin" ((("metadata" -> 'category'::"text")));



CREATE INDEX "documents_v2_meta_filename_trgm" ON "public"."documents_v2" USING "gin" ((("metadata" ->> 'file_name'::"text")) "public"."gin_trgm_ops");



CREATE INDEX "idx_documents_v2_file_name_ci" ON "public"."documents_v2" USING "btree" ("lower"("file_name"));



CREATE INDEX "idx_documents_v2_file_name_trgm" ON "public"."documents_v2" USING "gin" ("lower"("file_name") "public"."gin_trgm_ops");



CREATE OR REPLACE TRIGGER "documents_v2_fts_refresh_ins" BEFORE INSERT ON "public"."documents_v2" FOR EACH ROW EXECUTE FUNCTION "public"."documents_v2_fts_refresh"();



CREATE OR REPLACE TRIGGER "documents_v2_fts_refresh_upd" BEFORE UPDATE OF "content" ON "public"."documents_v2" FOR EACH ROW EXECUTE FUNCTION "public"."documents_v2_fts_refresh"();



CREATE OR REPLACE TRIGGER "trg_documents_v2_fill_from_metadata" BEFORE INSERT OR UPDATE ON "public"."documents_v2" FOR EACH ROW EXECUTE FUNCTION "public"."documents_v2_fill_from_metadata"();



CREATE OR REPLACE TRIGGER "trg_set_lang_from_metadata" BEFORE INSERT OR UPDATE ON "public"."documents_v2" FOR EACH ROW EXECUTE FUNCTION "public"."set_lang_from_metadata"();



ALTER TABLE "public"."documents" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."record_manager" ENABLE ROW LEVEL SECURITY;


GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";



GRANT ALL ON FUNCTION "public"."documents_v2_fill_from_metadata"() TO "anon";
GRANT ALL ON FUNCTION "public"."documents_v2_fill_from_metadata"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."documents_v2_fill_from_metadata"() TO "service_role";



GRANT ALL ON FUNCTION "public"."documents_v2_fts_refresh"() TO "anon";
GRANT ALL ON FUNCTION "public"."documents_v2_fts_refresh"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."documents_v2_fts_refresh"() TO "service_role";



GRANT ALL ON FUNCTION "public"."hybrid_search_v2"("query_text" "text", "query_embedding" "public"."vector", "match_count" integer, "filter" "jsonb", "lang" "text", "full_text_weight" double precision, "semantic_weight" double precision, "rrf_k" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."hybrid_search_v2"("query_text" "text", "query_embedding" "public"."vector", "match_count" integer, "filter" "jsonb", "lang" "text", "full_text_weight" double precision, "semantic_weight" double precision, "rrf_k" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."hybrid_search_v2"("query_text" "text", "query_embedding" "public"."vector", "match_count" integer, "filter" "jsonb", "lang" "text", "full_text_weight" double precision, "semantic_weight" double precision, "rrf_k" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."hybrid_search_v2_with_details"("p_query_text" "text", "p_query_embedding" "public"."vector", "p_match_count" integer, "p_filter" "jsonb", "p_lang" "text", "p_full_text_weight" double precision, "p_semantic_weight" double precision, "p_rrf_k" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."hybrid_search_v2_with_details"("p_query_text" "text", "p_query_embedding" "public"."vector", "p_match_count" integer, "p_filter" "jsonb", "p_lang" "text", "p_full_text_weight" double precision, "p_semantic_weight" double precision, "p_rrf_k" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."hybrid_search_v2_with_details"("p_query_text" "text", "p_query_embedding" "public"."vector", "p_match_count" integer, "p_filter" "jsonb", "p_lang" "text", "p_full_text_weight" double precision, "p_semantic_weight" double precision, "p_rrf_k" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."hybrid_search_v2_with_details_debug"("p_query_text" "text", "p_query_embedding" "public"."vector", "p_match_count" integer, "p_filter" "jsonb", "p_lang" "text", "p_full_text_weight" double precision, "p_semantic_weight" double precision, "p_rrf_k" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."hybrid_search_v2_with_details_debug"("p_query_text" "text", "p_query_embedding" "public"."vector", "p_match_count" integer, "p_filter" "jsonb", "p_lang" "text", "p_full_text_weight" double precision, "p_semantic_weight" double precision, "p_rrf_k" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."hybrid_search_v2_with_details_debug"("p_query_text" "text", "p_query_embedding" "public"."vector", "p_match_count" integer, "p_filter" "jsonb", "p_lang" "text", "p_full_text_weight" double precision, "p_semantic_weight" double precision, "p_rrf_k" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."match_documents"("query_embedding" "public"."vector", "match_count" integer, "filter" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."match_documents"("query_embedding" "public"."vector", "match_count" integer, "filter" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."match_documents"("query_embedding" "public"."vector", "match_count" integer, "filter" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."set_lang_from_metadata"() TO "anon";
GRANT ALL ON FUNCTION "public"."set_lang_from_metadata"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_lang_from_metadata"() TO "service_role";



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
