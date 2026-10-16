/* Libraries PHP's build links with, which config.w32 finds in the SDK's
 * deps: zlib and libxml2 from php8.dll, which exports them, and OpenSSL
 * from the libcrypto DLL PHP ships, through its import library. */
#include <stdio.h>
#include <string.h>
#include <zlib.h>
#include <libxml/parser.h>
#include <libxml/tree.h>
#include <openssl/crypto.h>
#include "greet.h"

void zprobe_libs(char *out, size_t size)
{
	const char *text = "hello";
	unsigned long crc = crc32(crc32(0L, Z_NULL, 0), (const Bytef *)text, (uInt)strlen(text));

	const char *xml = "<a><b>from libxml2</b></a>";
	xmlDocPtr doc = xmlReadMemory(xml, (int)strlen(xml), "zprobe.xml", NULL, 0);
	xmlChar *content = doc ? xmlNodeGetContent(xmlDocGetRootElement(doc)) : NULL;

	snprintf(out, size, "zlib %s crc %08lx, %s, OpenSSL %s",
		zlibVersion(), crc, content ? (const char *)content : "no document",
		OpenSSL_version(OPENSSL_VERSION_STRING));
	if (content) xmlFree(content);
	if (doc) xmlFreeDoc(doc);
}
