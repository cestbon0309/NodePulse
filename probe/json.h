#ifndef NP_JSON_H
#define NP_JSON_H
#include <ctype.h>
#include <stdlib.h>
#include <string.h>
typedef struct {
  int start, end, next, type;
} Token;
typedef struct {
  const char *s;
  size_t p;
  Token t[4096];
  int n;
} Json;
static int ws(Json *j) {
  while (isspace((unsigned char)j->s[j->p]))
    j->p++;
  return 0;
}
static int value(Json *j, int depth) {
  ws(j);
  if (depth > 32 || j->n == 4096)
    return -1;
  int i = j->n++;
  Token *t = &j->t[i];
  t->start = (int)j->p;
  t->type = j->s[j->p];
  char c = j->s[j->p++];
  if (c == '{' || c == '[') {
    ws(j);
    char end = c == '{' ? '}' : ']';
    if (j->s[j->p] != end)
      for (;;) {
        if (c == '{') {
          ws(j);
          if (j->s[j->p] != '"' || value(j, depth + 1) < 0)
            return -1;
          ws(j);
          if (j->s[j->p++] != ':')
            return -1;
        }
        if (value(j, depth + 1) < 0)
          return -1;
        ws(j);
        if (j->s[j->p] != ',')
          break;
        j->p++;
      }
    if (j->s[j->p++] != end)
      return -1;
  } else if (c == '"') {
    while (j->s[j->p] && j->s[j->p] != '"') {
      unsigned char x = j->s[j->p++];
      if (x < 32)
        return -1;
      if (x == '\\') {
        char e = j->s[j->p++];
        if (!e || !strchr("\"\\/bfnrtu", e))
          return -1;
        if (e == 'u')
          for (int k = 0; k < 4; k++)
            if (!isxdigit((unsigned char)j->s[j->p++]))
              return -1;
      }
    }
    if (j->s[j->p++] != '"')
      return -1;
  } else if (c == 't' || c == 'f' || c == 'n') {
    const char *v = c == 't' ? "true" : c == 'f' ? "false" : "null";
    size_t n = strlen(v);
    if (strncmp(j->s + t->start, v, n))
      return -1;
    j->p = (size_t)t->start + n;
  } else {
    j->p--;
    if (j->s[j->p] == '-')
      j->p++;
    if (j->s[j->p] == '0')
      j->p++;
    else {
      if (!isdigit((unsigned char)j->s[j->p]))
        return -1;
      while (isdigit((unsigned char)j->s[j->p]))
        j->p++;
    }
    if (j->s[j->p] == '.') {
      j->p++;
      if (!isdigit((unsigned char)j->s[j->p]))
        return -1;
      while (isdigit((unsigned char)j->s[j->p]))
        j->p++;
    }
    if (j->s[j->p] == 'e' || j->s[j->p] == 'E') {
      j->p++;
      if (j->s[j->p] == '+' || j->s[j->p] == '-')
        j->p++;
      if (!isdigit((unsigned char)j->s[j->p]))
        return -1;
      while (isdigit((unsigned char)j->s[j->p]))
        j->p++;
    }
  }
  t->end = (int)j->p;
  t->next = j->n;
  return i;
}
static int parse(Json *j, const char *s) {
  memset(j, 0, sizeof(*j));
  j->s = s;
  if (value(j, 0) != 0)
    return -1;
  ws(j);
  return s[j->p] ? -1 : 0;
}
static unsigned hex4(const char *s) {
  unsigned n = 0;
  for (int i = 0; i < 4; i++) {
    unsigned char c = s[i];
    n = n * 16 + (c <= '9' ? c - '0' : (c | 32) - 'a' + 10);
  }
  return n;
}
static char *string(Json *j, int i) {
  if (i < 0 || j->t[i].type != '"')
    return NULL;
  size_t len = (size_t)(j->t[i].end - j->t[i].start - 2);
  char *out = malloc(len + 1);
  if (!out)
    return NULL;
  size_t n = 0;
  for (int p = j->t[i].start + 1; p < j->t[i].end - 1; p++) {
    unsigned char c = j->s[p];
    if (c != '\\') {
      out[n++] = (char)c;
      continue;
    }
    c = j->s[++p];
    if (c == 'u') {
      unsigned cp = hex4(j->s + p + 1);
      p += 4;
      if (cp >= 0xd800 && cp <= 0xdbff) {
        if (p + 6 >= j->t[i].end || j->s[p + 1] != '\\' || j->s[p + 2] != 'u')
          goto bad;
        unsigned low = hex4(j->s + p + 3);
        if (low < 0xdc00 || low > 0xdfff)
          goto bad;
        cp = 0x10000 + ((cp - 0xd800) << 10) + low - 0xdc00;
        p += 6;
      } else if (cp >= 0xdc00 && cp <= 0xdfff)
        goto bad;
      if (!cp)
        goto bad;
      if (cp < 0x80)
        out[n++] = (char)cp;
      else if (cp < 0x800) {
        out[n++] = (char)(0xc0 | (cp >> 6));
        out[n++] = (char)(0x80 | (cp & 63));
      } else if (cp < 0x10000) {
        out[n++] = (char)(0xe0 | (cp >> 12));
        out[n++] = (char)(0x80 | ((cp >> 6) & 63));
        out[n++] = (char)(0x80 | (cp & 63));
      } else {
        out[n++] = (char)(0xf0 | (cp >> 18));
        out[n++] = (char)(0x80 | ((cp >> 12) & 63));
        out[n++] = (char)(0x80 | ((cp >> 6) & 63));
        out[n++] = (char)(0x80 | (cp & 63));
      }
    } else {
      const char *esc = "\"\\/bfnrt", *decoded = "\"\\/\b\f\n\r\t";
      out[n++] = decoded[strchr(esc, c) - esc];
    }
  }
  out[n] = 0;
  return out;
bad:
  free(out);
  return NULL;
}
static int eq(Json *j, int i, const char *s) {
  char *decoded = string(j, i);
  int match = decoded && !strcmp(decoded, s);
  free(decoded);
  return match;
}
static int field(Json *j, int obj, const char *s) {
  if (obj < 0 || j->t[obj].type != '{')
    return -1;
  for (int i = obj + 1; i < j->t[obj].next;) {
    int v = i + 1;
    if (eq(j, i, s))
      return v;
    i = j->t[v].next;
  }
  return -1;
}
#endif
