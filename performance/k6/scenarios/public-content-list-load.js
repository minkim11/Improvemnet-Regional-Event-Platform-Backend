import { check, fail } from 'k6';
import exec from 'k6/execution';
import { Counter, Rate, Trend } from 'k6/metrics';

import { apiBaseUrl, env, numberEnv, requiredEnv } from '../lib/config.js';
import { get, query, requestTags } from '../lib/http.js';
import { recordOutcome } from '../lib/responses.js';
import { markdownSummary } from '../lib/summary.js';

const scenarioName = 'public_content_list_load';
const testTag = 'public_content_list_load';
const rate = positiveIntegerEnv('PERF_RATE', 25);
const preAllocatedVUs = positiveIntegerEnv('PERF_PRE_ALLOCATED_VUS', rate * 2);
const duration = env('PERF_DURATION', '8m');
const requireNoDroppedIterations = env('PERF_REQUIRE_NO_DROPPED_ITERATIONS', 'true') !== 'false';
const apiBase = apiBaseUrl();
const regionId = requiredEnv('PERF_REGION_ID');

const contractErrorRate = new Rate('public_content_contract_error_rate');
const firstHalfDuration = new Trend('public_content_first_half_duration', true);
const secondHalfDuration = new Trend('public_content_second_half_duration', true);
const firstHalfRequests = new Counter('public_content_first_half_requests');
const secondHalfRequests = new Counter('public_content_second_half_requests');

const variants = [
  createVariant('region_only', {}, 200),
  createVariant('content_type', { contentType: 'EVENT_EXPERIENCE' }, 200),
  createVariant('available', { reservationAvailable: true }, 100, true),
  createVariant('unavailable', { reservationAvailable: false }, 100, false),
];

export const options = {
  scenarios: {
    [scenarioName]: {
      executor: 'constant-arrival-rate',
      rate,
      timeUnit: '1s',
      duration,
      preAllocatedVUs,
      gracefulStop: '0s',
      tags: { test: testTag },
    },
  },
  thresholds: {
    checks: ['rate==1'],
    ...(requireNoDroppedIterations ? { dropped_iterations: ['count==0'] } : {}),
    expected_outcome_rate: ['rate==1'],
    http_req_failed: ['rate==0'],
    public_content_contract_error_rate: ['rate==0'],
    system_failure_rate: ['rate==0'],
    unexpected_failure_rate: ['rate==0'],
  },
  summaryTrendStats: ['avg', 'min', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
};

export function handleSummary(data) {
  return markdownSummary(data, {
    title: 'k6 Public Content List Load Summary',
    scenario: 'public-content-list-load',
    testTag,
    baseUrl: env('PERF_BASE_URL', ''),
    apiBase,
    vus: preAllocatedVUs,
    duration,
    mode: `${rate} RPS constant-arrival-rate`,
  });
}

export default function () {
  const variant = variants[Number(exec.scenario.iterationInTest % variants.length)];
  const tags = requestTags(
    `publicContentsList.${variant.name}`,
    `GET /api/v1/contents (${variant.name})`,
    { test: testTag, variant: variant.name },
  );
  const response = get(
    apiBase,
    `/contents${query({ regionId, ...variant.parameters })}`,
    {},
    tags,
  );
  const outcome = recordOutcome(`GET /contents ${variant.name}`, response, {
    endpoint: `publicContentsList.${variant.name}`,
  });
  const contractValid = outcome.success && hasExpectedContract(
    outcome.body,
    variant.expectedCount,
    variant.expectedAvailability,
  );

  contractErrorRate.add(!contractValid, tags);
  check(response, {
    [`GET /contents ${variant.name}: status 200`]: (result) => result.status === 200,
    [`GET /contents ${variant.name}: contract`]: () => contractValid,
  }, tags);

  variant.durationMetric.add(response.timings.duration, tags);
  variant.responseBytesMetric.add(response.body ? response.body.length : 0, tags);

  if (exec.scenario.progress < 0.5) {
    firstHalfDuration.add(response.timings.duration, tags);
    firstHalfRequests.add(1, tags);
  } else {
    secondHalfDuration.add(response.timings.duration, tags);
    secondHalfRequests.add(1, tags);
  }
}

function createVariant(name, parameters, expectedCount, expectedAvailability) {
  return {
    name,
    parameters,
    expectedCount,
    expectedAvailability,
    durationMetric: new Trend(`public_content_${name}_duration`, true),
    responseBytesMetric: new Trend(`public_content_${name}_response_body_bytes`),
  };
}

function hasExpectedContract(body, expectedCount, expectedAvailability) {
  const contents = body && body.data && body.data.contents;
  if (!body
      || body.statusCode !== 200
      || body.code !== 'SUCCESS'
      || !Array.isArray(contents)
      || contents.length !== expectedCount) {
    return false;
  }

  return contents.every((content) => content
    && typeof content.contentId === 'string'
    && content.contentType === 'EVENT_EXPERIENCE'
    && typeof content.title === 'string'
    && typeof content.locationText === 'string'
    && typeof content.representativeImageUrl === 'string'
    && typeof content.representativeImageUrlExpiresAt === 'string'
    && typeof content.reservationAvailable === 'boolean'
    && (expectedAvailability === undefined
      || content.reservationAvailable === expectedAvailability));
}

function positiveIntegerEnv(name, defaultValue) {
  const value = numberEnv(name, defaultValue);
  if (!Number.isInteger(value) || value <= 0) {
    fail(`Environment variable ${name} must be a positive integer: ${value}`);
  }
  return value;
}
