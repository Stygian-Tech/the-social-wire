"use client";

import { useEffect, useRef, useState } from "react";

/** The official embed owns market data; the app observes only frame loading. */
export function FinanceTradingView({symbol,hidden,widgetsEnabled}:{symbol?:string;hidden:boolean;widgetsEnabled:boolean}) {
  const host = useRef<HTMLDivElement>(null);
  const widget = useRef<HTMLDivElement>(null);
  const [visible,setVisible] = useState(false);
  const [theme,setTheme] = useState(() => typeof document !== "undefined" && document.documentElement.classList.contains("dark") ? "dark" : "light");
  const [status,setStatus] = useState<"loading"|"ready"|"unavailable">("loading");
  const enabled = widgetsEnabled && process.env.NEXT_PUBLIC_FINANCE_WIDGETS_ENABLED === "true" && !hidden && !!symbol && /^[A-Za-z0-9_\-]+:[A-Za-z0-9_.!\-]+$/.test(symbol);

  useEffect(() => {
    const observer = new window.MutationObserver(() => setTheme(document.documentElement.classList.contains("dark") ? "dark" : "light"));
    observer.observe(document.documentElement,{attributes:true,attributeFilter:["class"]});
    return () => observer.disconnect();
  },[]);
  useEffect(() => {
    if (!enabled || !host.current) return;
    const observer = new IntersectionObserver(rows => {
      if (rows.some(row => row.isIntersecting)) {setVisible(true);observer.disconnect();}
    });
    observer.observe(host.current);
    return () => observer.disconnect();
  },[enabled]);
  useEffect(() => {
    const element = host.current;
    const target = widget.current;
    if (!enabled || !visible || !element || !target) return;
    let active = true;
    const timer = window.setTimeout(() => {if(active) setStatus("unavailable");},12000);
    const script = document.createElement("script");
    script.type = "text/javascript";
    script.src = "https://s3.tradingview.com/external-embedding/embed-widget-symbol-overview.js";
    script.async = true;
    script.text = JSON.stringify({symbols:[[`${symbol}|1D`]],chartOnly:false,width:"100%",height:300,locale:"en",colorTheme:theme,autosize:false,showVolume:false});
    const fail = () => {if(active){window.clearTimeout(timer);setStatus("unavailable");}};
    const ready = () => {if(active){window.clearTimeout(timer);setStatus("ready");}};
    script.addEventListener("error",fail);
    let frame:HTMLIFrameElement|null = null;
    const observer = new window.MutationObserver(() => {
      const next = target.querySelector("iframe");
      if (next && next !== frame) {frame?.removeEventListener("load",ready);frame = next;frame.addEventListener("load",ready);}
    });
    observer.observe(target,{childList:true,subtree:true});
    element.appendChild(script);
    return () => {active=false;window.clearTimeout(timer);observer.disconnect();frame?.removeEventListener("load",ready);script.removeEventListener("error",fail);script.remove();target.replaceChildren();};
  },[enabled,visible,symbol,theme]);

  if (!enabled) return null;
  return (
    <section aria-label="Market Overview" className="my-4">
      <div ref={host} className="tradingview-widget-container">
        <div ref={widget} className="tradingview-widget-container__widget min-h-[300px]" />
        <div className="tradingview-widget-copyright">
          <a href="https://www.tradingview.com/" target="_blank" rel="noopener nofollow noreferrer"><span className="blue-text">Track All Markets on TradingView</span></a>
        </div>
      </div>
      {status === "unavailable" ? <p role="status" className="text-xs text-muted-foreground">Market data is unavailable or taking longer to load. You can continue reading.</p> : null}
    </section>
  );
}
