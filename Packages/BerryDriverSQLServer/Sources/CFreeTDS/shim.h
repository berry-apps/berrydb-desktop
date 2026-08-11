#ifndef CFREETDS_SHIM_H
#define CFREETDS_SHIM_H
#include <sybfront.h>
#include <sybdb.h>

// FreeTDS's DBSETLUSER/DBSETLPWD/DBSETLAPP (sybdb.h) are function-like C
// macros — Swift's Clang importer cannot import these ("function like macros
// not supported", confirmed via a real build error, not assumed). Plain
// object-like macros (SUCCEED, FAIL, NO_MORE_ROWS, INT_CANCEL, ...) import
// fine as real constants and need no wrapper. Wrap only the three
// function-like ones as real C functions so Swift calls a typed function
// instead of hardcoding FreeTDS's internal DBSETUSER/DBSETPWD/DBSETAPP
// numeric values.
static inline RETCODE cfreetds_dbsetluser(LOGINREC *login, const char *value) {
    return dbsetlname(login, value, DBSETUSER);
}
static inline RETCODE cfreetds_dbsetlpwd(LOGINREC *login, const char *value) {
    return dbsetlname(login, value, DBSETPWD);
}
static inline RETCODE cfreetds_dbsetlapp(LOGINREC *login, const char *value) {
    return dbsetlname(login, value, DBSETAPP);
}

#endif
