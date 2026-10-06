const config = window.SPIKE_CONFIG || { apiBaseUrl: "/api" };
const form = document.querySelector("#portrait-form");
const statusLine = document.querySelector("#status");
const submit = form.querySelector("button");
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

document.querySelector("#mode").textContent = config.imageBackend === "bedrock"
  ? "Image generation uses Bedrock and may incur AWS charges per upload."
  : "Floci test mode returns an unchanged copy. Run make SPIKE=spike-3 apply-bedrock AWS_PROFILE=dinu to enable image generation.";

form.addEventListener("submit", async event => {
  event.preventDefault();
  const file = document.querySelector("#photo").files[0];
  const prompt = document.querySelector("#prompt").value;
  if (!file) return;
  submit.disabled = true;
  document.querySelector("#result").hidden = true;
  try {
    statusLine.textContent = "Preparing a private upload…";
    const created = await fetch(`${config.apiBaseUrl}/jobs`, {
      method: "POST", headers: { "content-type": "application/json" },
      body: JSON.stringify({ content_type: file.type, size: file.size, prompt })
    });
    const job = await created.json();
    if (!created.ok) throw new Error(job.error || "Could not start the job.");
    const uploaded = await fetch(job.upload_url, {
      method: "PUT", headers: { "content-type": job.upload_content_type }, body: file
    });
    if (!uploaded.ok) throw new Error("The image upload failed.");
    statusLine.textContent = "Image received. Creating your portrait…";
    for (let attempt = 0; attempt < 180; attempt++) {
      await sleep(2000);
      const response = await fetch(`${config.apiBaseUrl}/jobs/${job.job_id}`);
      const state = await response.json();
      if (state.status === "COMPLETED") {
        document.querySelector("#portrait").src = state.result_url;
        document.querySelector("#download").href = state.result_url;
        document.querySelector("#result").hidden = false;
        statusLine.textContent = "Your portrait is ready.";
        return;
      }
      if (state.status === "FAILED") throw new Error(state.error || "Portrait generation failed.");
    }
    throw new Error("This is taking longer than expected. Reload and try again.");
  } catch (error) {
    statusLine.textContent = error.message;
  } finally {
    submit.disabled = false;
  }
});
