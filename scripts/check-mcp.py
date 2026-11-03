#!/usr/bin/env python3
"""Read-only MCP integration check. Runs a real stdio client against the built server."""
import argparse, json, os, selectors, subprocess, time
from pathlib import Path

class Client:
    def __init__(self, server, config=None):
        env = dict(os.environ)
        if config: env["DIGUP_SETTINGS_FILE"] = str(Path(config).resolve())
        self.log = open(Path(server).parent / "mcp-check.stderr.log", "w")
        self.process = subprocess.Popen([server], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=self.log, text=True, bufsize=1, env=env)
        self.next_id = 0
        self.request("initialize", {"protocolVersion":"2025-11-25","capabilities":{},
                                    "clientInfo":{"name":"digup-verification","version":"1"}})
        self.send({"jsonrpc":"2.0","method":"notifications/initialized"})

    def send(self, value):
        self.process.stdin.write(json.dumps(value)+"\n")
        self.process.stdin.flush()

    def request(self, method, params):
        self.next_id += 1
        ident = self.next_id
        self.send({"jsonrpc":"2.0","id":ident,"method":method,"params":params})
        deadline = time.monotonic()+90
        while time.monotonic() < deadline:
            selector = selectors.DefaultSelector()
            selector.register(self.process.stdout, selectors.EVENT_READ)
            ready = selector.select(max(0,deadline-time.monotonic()))
            selector.close()
            if not ready: raise TimeoutError(method)
            line = self.process.stdout.readline()
            if not line: raise RuntimeError("Server exited: "+str(self.process.poll()))
            value = json.loads(line)
            if value.get("id") != ident: continue
            if "error" in value: raise RuntimeError(value["error"])
            return value["result"]
        raise TimeoutError(method)

    def tool(self, name, arguments, error=False):
        result = self.request("tools/call", {"name":name,"arguments":arguments})
        if bool(result.get("isError")) != error:
            raise AssertionError((name, arguments, result))
        return result

    def close(self):
        self.process.stdin.close()
        try: self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            self.process.wait(timeout=5)
        self.log.close()

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument("server")
    parser.add_argument("--config")
    parser.add_argument("--image")
    parser.add_argument("--audio")
    parser.add_argument("--text",default="payment declined")
    parser.add_argument("--output")
    args=parser.parse_args()
    start=time.monotonic()
    client=Client(str(Path(args.server).resolve()), args.config)
    report={"checks":[]}
    try:
        tools=client.request("tools/list",{})["tools"]
        assert {t["name"] for t in tools} == {"digup_search_files","digup_get_result_context","digup_index_status"}
        assert all(t["annotations"]["readOnlyHint"] and not t["annotations"]["destructiveHint"] for t in tools)
        report["checks"].append("discovery_and_readonly_annotations")
        report["status"]=client.tool("digup_index_status",{})["structuredContent"]
        report["checks"].append("status_without_model_loading")
        for invalid in [{}, {"text":"cat","image_path":"/tmp/test.png"}, {"text":42},
                        {"text":"cat","limit":101}, {"image_path":"relative.png"},
                        {"audio_path":"/missing.wav"}, {"text":"cat","duration_seconds":1},
                        {"text":"cat","kinds":["invented"]}]:
            client.tool("digup_search_files",invalid,error=True)
        report["checks"].append("invalid_arguments")
        client.tool("digup_get_result_context",{"result_id":"files:../../private"},error=True)
        report["checks"].append("context_identifier_validation")
        queries=[("text",{"text":args.text})]
        if args.image: queries.append(("image",{"image_path":str(Path(args.image).resolve())}))
        if args.audio: queries.append(("audio",{"audio_path":str(Path(args.audio).resolve())}))
        for label, query in queries:
            result=client.tool("digup_search_files",{**query,"limit":5})["structuredContent"]
            assert result["semantic"], (label,result)
            report[label]={"count":len(result["results"]), "paths":[r["path"] for r in result["results"]]}
            if result["results"]:
                context=client.tool("digup_get_result_context",{"result_id":result["results"][0]["result_id"]})
                assert context["structuredContent"]["result"]["path"] == result["results"][0]["path"]
            report["checks"].append(label+"_search_and_context")
        empty=client.tool("digup_search_files",{"text":"zxqv8672unlikelyexactlookup","offset":10000})["structuredContent"]
        assert empty["results"] == [] and not empty["has_more"]
        report["checks"].append("empty_page")
        report["elapsed_seconds"]=round(time.monotonic()-start,2)
        if args.output: Path(args.output).write_text(json.dumps(report,indent=2))
        print(json.dumps({"checks":report["checks"],"indexed":report["status"]["indexed"],
                          "elapsed_seconds":report["elapsed_seconds"]}))
    finally: client.close()

if __name__ == "__main__": main()
