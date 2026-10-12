"use client";

import { floatingGlassClasses } from "@/components/shared/floatingChromeStyles";

import { ChevronLeft, ChevronRight } from "lucide-react";
import { Button } from "@/components/ui/button";
import { calendarMonthDays, localCalendarDate } from "./calendarDates";

export function CalendarMonth({ month, selectedDay, counts, onMonthChange, onSelectDay }: { month: Date; selectedDay: string; counts: Record<string, number>; onMonthChange: (date: Date) => void; onSelectDay: (day: string) => void }) {
  return <div className={`${floatingGlassClasses} p-3`}>
    <div className="mb-3 flex items-center justify-between"><Button aria-label="Previous Month" size="icon" variant="ghost" onClick={() => onMonthChange(new Date(month.getFullYear(), month.getMonth() - 1, 1))}><ChevronLeft aria-hidden="true" /></Button><h2 className="font-semibold">{month.toLocaleDateString(undefined, { month: "long", year: "numeric" })}</h2><Button aria-label="Next Month" size="icon" variant="ghost" onClick={() => onMonthChange(new Date(month.getFullYear(), month.getMonth() + 1, 1))}><ChevronRight aria-hidden="true" /></Button></div>
    <div className="grid grid-cols-7 gap-1">{["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"].map(day => <span key={day} className="py-1 text-center text-xs text-muted-foreground">{day}</span>)}{calendarMonthDays(month).map(date => { const day = localCalendarDate(date); return <button key={day} type="button" aria-pressed={day === selectedDay} aria-label={`${date.toLocaleDateString(undefined, { weekday: "long", month: "long", day: "numeric", year: "numeric" })}${counts[day] ? `, ${counts[day]} Posts` : ""}`} onClick={() => onSelectDay(day)} className={`flex min-h-14 flex-col items-center justify-center rounded-xl text-sm sm:min-h-20 ${day === selectedDay ? "bg-accent ring-1 ring-primary" : "hover:bg-accent"} ${date.getMonth() !== month.getMonth() ? "text-muted-foreground" : ""}`}><span>{date.getDate()}</span>{counts[day] ? <span className="mt-1 rounded-full bg-primary/15 px-1.5 text-xs">{counts[day]}</span> : null}</button>; })}</div>
  </div>;
}
