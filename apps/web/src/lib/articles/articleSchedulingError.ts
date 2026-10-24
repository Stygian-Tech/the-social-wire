/** No schedule-creation request was sent; a newly reserved local draft can be unlocked. */
export class ArticleSchedulingNotSubmittedError extends Error {
  constructor(cause: unknown) {
    super(cause instanceof Error ? cause.message : "The Article Could Not Be Prepared.", { cause });
    this.name = "ArticleSchedulingNotSubmittedError";
  }
}
