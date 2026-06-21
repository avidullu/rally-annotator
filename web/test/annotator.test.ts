import { describe, it, expect } from "vitest";
import { Annotator } from "../src/state/annotator";
import { parseRows, serializeRows, HEADER } from "../src/state/csv";

// Build an Annotator with a capturing persist (records the serialized CSV each write).
function make(rowsCsv = "") {
  const store = { csv: "", writes: 0 };
  const a = new Annotator({
    rows: rowsCsv ? parseRows(HEADER + rowsCsv) : [],
    persist: (rows) => {
      store.csv = serializeRows(rows);
      store.writes++;
      return { ok: true };
    },
  });
  return { a, store };
}

describe("numbering", () => {
  it("continues from max existing rally_number", () => {
    const { a } = make("1,1.0,2.0,winner,badminton,\n5,3.0,4.0,let,tennis,\n");
    expect(a.nextRallyNumber()).toBe(6);
    expect(a.nextField).toBe("6"); // initialized on construction
  });

  it("starts at 1 when empty", () => {
    const { a } = make();
    expect(a.nextRallyNumber()).toBe(1);
    expect(a.nextField).toBe("1");
  });

  it("nextFreeFrom skips occupied numbers", () => {
    const { a } = make("1,1,2,winner,badminton,\n2,3,4,let,tennis,\n4,5,6,winner,padel,\n");
    expect(a.nextFreeFrom(1)).toBe(3);
    expect(a.nextFreeFrom(3)).toBe(3);
    expect(a.nextFreeFrom(4)).toBe(5);
  });
});

describe("two-step commit + non-sticky reason/shots, sticky sport", () => {
  it("marks then saves; nothing is written until Save", () => {
    const { a, store } = make();
    expect(a.markStart(8.8).ok).toBe(true);
    expect(a.startField).toBe("8.800");
    expect(a.rows.length).toBe(0);
    expect(a.markEnd(11.5).ok).toBe(true);
    expect(a.endField).toBe("11.500");
    expect(a.isArmed()).toBe(true);
    expect(a.rows.length).toBe(0); // still nothing saved

    a.reason = "winner";
    a.shotsField = "9";
    const res = a.saveRally();
    expect(res.ok).toBe(true);
    expect(a.rows.length).toBe(1);
    expect(a.rows[0]).toMatchObject({ n: 1, s: 8.8, e: 11.5, reason: "winner", sport: "badminton", shots: "9" });
    expect(store.csv).toContain("1,8.800,11.500,winner,badminton,9");
  });

  it("resets reason and shots after save, keeps sport, advances next #", () => {
    const { a } = make();
    a.sport = "tennis";
    a.markStart(1);
    a.markEnd(2);
    a.reason = "let";
    a.shotsField = "7";
    a.saveRally();
    expect(a.reason).toBe("unknown"); // non-sticky
    expect(a.shotsField).toBe(""); // non-sticky
    expect(a.sport).toBe("tennis"); // sticky
    expect(a.startField).toBe("");
    expect(a.endField).toBe("");
    expect(a.nextField).toBe("2");
  });

  it("treats shots=0 as a valid count (not blank)", () => {
    const { a } = make();
    a.markStart(1);
    a.markEnd(2);
    a.shotsField = " 0 ";
    a.saveRally();
    expect(a.rows[0].shots).toBe("0");
  });

  it("blank/negative shots record no count", () => {
    const { a } = make();
    a.markStart(1);
    a.markEnd(2);
    a.shotsField = "-3";
    a.saveRally();
    expect(a.rows[0].shots).toBe(null);
  });
});

describe("validation", () => {
  it("swaps reversed marks (end < start)", () => {
    const { a } = make();
    a.markStart(10);
    a.markEnd(5);
    a.saveRally();
    expect(a.rows[0]).toMatchObject({ s: 5, e: 10 });
  });

  it("refuses a zero-length rally (end <= start)", () => {
    const { a } = make();
    a.markStart(5);
    a.markEnd(5);
    const res = a.saveRally();
    expect(res.ok).toBe(false);
    expect(a.rows.length).toBe(0);
  });

  it("refuses a duplicate rally number", () => {
    const { a } = make("2,1,2,winner,badminton,\n");
    a.nextField = "2";
    a.markStart(3);
    a.markEnd(4);
    const res = a.saveRally();
    expect(res.ok).toBe(false);
    expect(res.key).toBe("status.duplicate");
  });
});

describe("unsaved-rally guard (v1.6.4)", () => {
  it("refuses Mark START while a rally is armed", () => {
    const { a } = make();
    a.markStart(1);
    a.markEnd(2);
    const res = a.markStart(3);
    expect(res.ok).toBe(false);
    expect(res.key).toBe("status.unsavedGuard");
    expect(a.startField).toBe("1.000"); // unchanged
  });

  it("refuses Edit selected while a rally is armed", () => {
    const { a } = make("1,1,2,winner,badminton,\n");
    a.markStart(3);
    a.markEnd(4);
    const res = a.editSelected(1);
    expect(res.ok).toBe(false);
    expect(a.mode).toBe("new");
  });
});

describe("3-way undo", () => {
  it("cancels an edit", () => {
    const { a } = make("1,1,2,winner,badminton,\n");
    a.editSelected(1);
    expect(a.mode).toBe("edit");
    const res = a.undoLast();
    expect(res.key).toBe("status.editCancelled");
    expect(a.mode).toBe("new");
  });

  it("clears an in-progress mark without writing", () => {
    const { a, store } = make();
    a.markStart(1);
    const res = a.undoLast();
    expect(res.key).toBe("status.clearedMark");
    expect(a.startField).toBe("");
    expect(store.writes).toBe(0);
  });

  it("drops the last committed row and resyncs next #", () => {
    const { a } = make("1,1,2,winner,badminton,\n2,3,4,let,tennis,\n");
    const res = a.undoLast();
    expect(res.ok).toBe(true);
    expect(a.rows.map((r) => r.n)).toEqual([1]);
    expect(a.nextField).toBe("2");
  });

  it("reports nothing to undo on an empty, idle form", () => {
    const { a } = make();
    expect(a.undoLast().ok).toBe(false);
  });
});

describe("edit mode", () => {
  it("relabels Mark/Save buttons to make edit mode unmissable", () => {
    const { a } = make("3,1,2,winner,badminton,\n");
    a.editSelected(3);
    expect(a.markStartLabel()).toEqual({ key: "btn.reMarkStart", params: { n: 3 } });
    expect(a.markEndLabel()).toEqual({ key: "btn.reMarkEnd", params: { n: 3 } });
    expect(a.saveLabel()).toEqual({ key: "btn.saveChangesN", params: { n: 3 } });
  });

  it("loads the row's fields (incl. shots) and keeps the same rally_number on save", () => {
    const { a } = make("3,1.000,2.000,winner,badminton,9\n");
    a.editSelected(3);
    expect(a.startField).toBe("1.000");
    expect(a.endField).toBe("2.000");
    expect(a.shotsField).toBe("9");
    expect(a.reason).toBe("winner");
    a.endField = "5.000";
    a.reason = "let";
    const res = a.saveRally();
    expect(res.ok).toBe(true);
    expect(a.rows[0]).toMatchObject({ n: 3, e: 5, reason: "let" });
    expect(a.mode).toBe("new"); // back to new after committing the edit
  });
});

describe("delete", () => {
  it("removes a row and resyncs the next # field", () => {
    const { a } = make("1,1,2,winner,badminton,\n2,3,4,let,tennis,\n");
    const res = a.deleteSelected(1);
    expect(res.ok).toBe(true);
    expect(a.rows.map((r) => r.n)).toEqual([2]);
    expect(a.nextField).toBe("3"); // max(2)+1
  });
});

describe("save-button label in new mode", () => {
  it("shows the planned number once both times are set", () => {
    const { a } = make();
    expect(a.saveLabel()).toEqual({ key: "btn.saveRally" });
    a.markStart(1);
    a.markEnd(2);
    expect(a.saveLabel()).toEqual({ key: "btn.saveRallyN", params: { n: 1 } });
  });
});

describe("write-failure rollback", () => {
  function failing(rowsCsv = "") {
    return new Annotator({
      rows: rowsCsv ? parseRows(HEADER + rowsCsv) : [],
      persist: () => ({ ok: false, err: "disk full" }),
    });
  }

  it("rolls back a new save when the write fails", () => {
    const a = failing();
    a.markStart(1);
    a.markEnd(2);
    const res = a.saveRally();
    expect(res.ok).toBe(false);
    expect(res.key).toBe("status.writeFailed");
    expect(a.rows).toHaveLength(0);
  });

  it("restores the row when an edit fails to write", () => {
    const a = failing("1,1.000,2.000,winner,badminton,\n");
    a.editSelected(1);
    a.endField = "9.000";
    expect(a.saveRally().ok).toBe(false);
    expect(a.rows[0].e).toBe(2); // unchanged
  });

  it("restores the row when delete fails to write", () => {
    const a = failing("1,1,2,winner,badminton,\n");
    expect(a.deleteSelected(1).ok).toBe(false);
    expect(a.rows).toHaveLength(1);
  });

  it("restores the row when undo fails to write", () => {
    const a = failing("1,1,2,winner,badminton,\n");
    expect(a.undoLast().ok).toBe(false);
    expect(a.rows).toHaveLength(1);
  });
});
