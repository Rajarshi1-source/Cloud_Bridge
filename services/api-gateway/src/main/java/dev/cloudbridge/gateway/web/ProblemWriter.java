package dev.cloudbridge.gateway.web;

import jakarta.servlet.http.HttpServletResponse;
import tools.jackson.databind.json.JsonMapper;

import org.springframework.http.MediaType;
import org.springframework.http.ProblemDetail;

import java.io.IOException;
import java.util.LinkedHashMap;
import java.util.Map;

/** Writes RFC 9457 bodies from servlet filters (outside Spring MVC's message converters). */
final class ProblemWriter {

	private static final JsonMapper JSON = JsonMapper.builder().build();

	private ProblemWriter() {
	}

	static void write(HttpServletResponse res, ProblemDetail pd) throws IOException {
		Map<String, Object> body = new LinkedHashMap<>();
		body.put("type", pd.getType().toString());
		body.put("title", pd.getTitle());
		body.put("status", pd.getStatus());
		body.put("detail", pd.getDetail());
		if (pd.getProperties() != null) {
			body.putAll(pd.getProperties()); // extensions are top-level members, as RFC 9457 specifies
		}
		res.setStatus(pd.getStatus());
		res.setContentType(MediaType.APPLICATION_PROBLEM_JSON_VALUE);
		JSON.writeValue(res.getOutputStream(), body);
	}

}
