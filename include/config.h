/**
 * @file config.h
 * @brief Parse ./pipeline.conf into WorkerConfig array.
 *
 * Config file format (one line per rank, # = comment):
 *
 *   # rank  role         recv_from  send_to(space-sep)    omp_threads  width   height
 *   0       INGESTION    -1         1                      4            640     480
 *   1       GRAYSCALE    0          2 3 4                  4            640     480
 *   2       CONVOLUTION  1          5                      4            640     480
 *   3       CONVOLUTION  1          5                      4            640     480
 *   4       CONVOLUTION  1          5                      4            640     480
 *   5       THRESHOLD    2          0                      4            640     480
 */

#pragma once
#include "pipeline.h"
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <vector>

static inline int parse_role(const char* s) {
    if (strcmp(s, "INGESTION")   == 0) return ROLE_INGESTION;
    if (strcmp(s, "GRAYSCALE")   == 0) return ROLE_GRAYSCALE;
    if (strcmp(s, "CONVOLUTION") == 0) return ROLE_CONVOLUTION;
    if (strcmp(s, "THRESHOLD")   == 0) return ROLE_THRESHOLD;
    return ROLE_UNKNOWN;
}

/**
 * @brief Parse the pipeline config file.
 * @param path        Path to config file.
 * @param out_configs Output vector, indexed by rank.
 * @return true on success, false on parse error.
 */
static inline bool parse_config(const char* path,
                                std::vector<WorkerConfig>& out_configs) {
    FILE* f = fopen(path, "r");
    if (!f) {
        fprintf(stderr, "[config] ERROR: cannot open '%s'\n", path);
        return false;
    }

    char line[512];
    int  line_no = 0;

    while (fgets(line, sizeof(line), f)) {
        line_no++;

        // Strip comments and blank lines
        char* comment = strchr(line, '#');
        if (comment) *comment = '\0';
        if (strspn(line, " \t\r\n") == strlen(line)) continue;

        // rank  role  recv_from  [send_to...]  omp_threads  width  height
        // We parse token by token.
        WorkerConfig cfg;
        memset(&cfg, -1, sizeof(cfg));  // -1 means "unused"
        cfg.send_to_count = 0;

        char role_str[32] = {0};
        char* tok = strtok(line, " \t\r\n");

        // rank
        if (!tok) { fprintf(stderr, "[config] line %d: missing rank\n", line_no); fclose(f); return false; }
        cfg.rank = atoi(tok);

        // role
        tok = strtok(NULL, " \t\r\n");
        if (!tok) { fprintf(stderr, "[config] line %d: missing role\n", line_no); fclose(f); return false; }
        strncpy(role_str, tok, sizeof(role_str) - 1);
        cfg.role = parse_role(role_str);
        if (cfg.role == ROLE_UNKNOWN) {
            fprintf(stderr, "[config] line %d: unknown role '%s'\n", line_no, role_str);
            fclose(f); return false;
        }

        // recv_from
        tok = strtok(NULL, " \t\r\n");
        if (!tok) { fprintf(stderr, "[config] line %d: missing recv_from\n", line_no); fclose(f); return false; }
        cfg.recv_from = atoi(tok);  // -1 means no input (ingestion reads from network)

        // send_to list — read tokens until we hit something that doesn't look
        // like a small integer (> 100 = likely omp_threads or width/height)
        // Strategy: read up to MAX_SEND_TO tokens, then omp_threads, width, height
        for (int i = 0; i < MAX_SEND_TO; ++i) {
            tok = strtok(NULL, " \t\r\n");
            if (!tok) { fprintf(stderr, "[config] line %d: missing send_to or omp_threads\n", line_no); fclose(f); return false; }
            int v = atoi(tok);
            // omp_threads will be >= 1 and typically <= 32.
            // We distinguish send_to from omp_threads by a sentinel token "|"
            // OR by the fact that we've read MAX_SEND_TO entries already.
            // Simpler: use "|" as separator in config.
            if (strcmp(tok, "|") == 0) {
                // next token is omp_threads
                break;
            }
            if (cfg.send_to_count < MAX_SEND_TO) {
                cfg.send_to[cfg.send_to_count++] = v;
            }
        }

        // omp_threads
        tok = strtok(NULL, " \t\r\n");
        if (!tok) { fprintf(stderr, "[config] line %d: missing omp_threads\n", line_no); fclose(f); return false; }
        cfg.omp_threads = atoi(tok);

        // width
        tok = strtok(NULL, " \t\r\n");
        if (!tok) { fprintf(stderr, "[config] line %d: missing width\n", line_no); fclose(f); return false; }
        cfg.image_width = atoi(tok);

        // height
        tok = strtok(NULL, " \t\r\n");
        if (!tok) { fprintf(stderr, "[config] line %d: missing height\n", line_no); fclose(f); return false; }
        cfg.image_height = atoi(tok);

        // Grow output vector if needed
        if (cfg.rank >= (int)out_configs.size()) {
            out_configs.resize(cfg.rank + 1);
        }
        out_configs[cfg.rank] = cfg;

        fprintf(stderr, "[config] rank %d: role=%s recv_from=%d send_to_count=%d omp=%d %dx%d\n",
                cfg.rank, role_str, cfg.recv_from,
                cfg.send_to_count, cfg.omp_threads,
                cfg.image_width, cfg.image_height);
    }

    fclose(f);
    fprintf(stderr, "[config] loaded %zu worker configs\n", out_configs.size());
    return true;
}
