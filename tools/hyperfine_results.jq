# A pipe cannot be truncated when Hyperfine rewrites its export after each
# command. Slurp those cumulative documents and accept only the final set.
def duration: type == "number" and isfinite and . >= 0;
last.results |
if type != "array" then error("missing final Hyperfine result array")
elif (map(.command) | sort) != ($expected | sort) then
  error("final Hyperfine implementation set is incomplete or duplicated")
elif (all(.[];
  ([.mean, .median, .user, .system] | all(duration)) and
  has("stddev") and (.stddev == null or (.stddev | duration))) | not) then
  error("final Hyperfine results contain missing or invalid timings")
else .[] end
