// k6 step-spike load profile — drives CPU on scaleout-app to trip the HPA.
// Reference profile for an externally exposed (ALB + TLS) variant of the app;
// the published benchmark itself uses the in-cluster loader (load/loadgen.yaml).
// Usage: k6 run -e TARGET_URL=https://<your-alb-endpoint> load/spike.js
//
// Baseline low load, then a sharp step spike to force HPA 10 -> 300.
// Tune arrival rates to your app's per-pod capacity so 300 pods is the steady target.
import http from 'k6/http';
import { sleep } from 'k6';

// Serve the app behind TLS (e.g., ALB with an ACM certificate) and pass the
// HTTPS endpoint via TARGET_URL.
const TARGET = __ENV.TARGET_URL || 'https://scaleout-app.example.com';

export const options = {
  scenarios: {
    baseline: {
      executor: 'constant-arrival-rate',
      rate: 50, timeUnit: '1s', duration: '2m',
      preAllocatedVUs: 50, maxVUs: 200,
    },
    spike: {
      executor: 'ramping-arrival-rate',
      startTime: '2m',
      startRate: 50, timeUnit: '1s',
      preAllocatedVUs: 200, maxVUs: 5000,
      stages: [
        { target: 5000, duration: '10s' },  // sharp step — the "thundering herd"
        { target: 5000, duration: '8m' },    // hold so scale-out completes + stabilizes
      ],
    },
  },
};

export default function () {
  http.get(TARGET);
  sleep(0.1);
}
