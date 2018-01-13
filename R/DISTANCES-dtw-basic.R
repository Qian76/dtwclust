#' Basic DTW distance
#'
#' This is a custom implementation of the DTW algorithm without all the functionality included in
#' [dtw::dtw()]. Because of that, it should be faster, while still supporting the most common
#' options.
#'
#' @export
#' @importFrom dtw symmetric1
#' @importFrom dtw symmetric2
#'
#' @param x,y Time series. Multivariate series must have time spanning the rows and variables
#'   spanning the columns.
#' @param window.size Size for slanted band window. `NULL` means no constraint.
#' @param norm Norm for the DTW calculation, "L1" for Manhattan or "L2" for Euclidean.
#' @param step.pattern Step pattern for DTW. Only `symmetric1` or `symmetric2` supported here. Note
#'   that these are *not* characters. See [dtw::stepPattern].
#' @param backtrack Also compute the warping path between series? See details.
#' @param normalize Should the distance be normalized? Only supported for `symmetric2`.
#' @param ... Currently ignored.
#' @param gcm Optionally, a matrix to use for the global cost matrix calculations. It should have
#'   `NROW(y)+1` columns, and `NROW(x)+1` rows for `backtrack = TRUE` **or** `2` rows for `backtrack
#'   = FALSE`. Used internally for memory optimization. If provided, it **will** be modified *in
#'   place* by `C` code, except in the parallel version in [proxy::dist()] which ignores it for
#'   thread-safe reasons.
#' @template error-check
#'
#' @details
#'
#' If `backtrack` is `TRUE`, the mapping of indices between series is returned in a list.
#'
#' @template window
#'
#' @return The DTW distance. For `backtrack` `=` `TRUE`, a list with:
#'
#'   - `distance`: The DTW distance.
#'   - `index1`: `x` indices for the matched elements in the warping path.
#'   - `index2`: `y` indices for the matched elements in the warping path.
#'
#' @template proxy
#' @template symmetric
#' @section Proxy version:
#'
#'   In order for symmetry to apply here, the following must be true: no window constraint is used
#'   (`window.size` is `NULL`) or, if one is used, all series have the same length.
#'
#' @note
#'
#' The DTW algorithm (and the functions that depend on it) might return different values in 32 bit
#' installations compared to 64 bit ones.
#'
#' @example man-examples/multivariate-dtw.R
#'
dtw_basic <- function(x, y, window.size = NULL, norm = "L1",
                      step.pattern = dtw::symmetric2, backtrack = FALSE,
                      normalize = FALSE, ..., gcm = NULL, error.check = TRUE)
{
    if (error.check) {
        check_consistency(x, "ts")
        check_consistency(y, "ts")
    }

    if (is.null(window.size))
        window.size <- -1L
    else
        window.size <- check_consistency(window.size, "window")

    if (NCOL(x) != NCOL(y)) stop("Multivariate series must have the same number of variables.")

    if (identical(step.pattern, dtw::symmetric1))
        step.pattern <- 1
    else if (identical(step.pattern, dtw::symmetric2))
        step.pattern <- 2
    else
        stop("step.pattern must be either symmetric1 or symmetric2 (without quotes)")

    norm <- match.arg(norm, c("L1", "L2"))
    norm <- switch(norm, "L1" = 1, "L2" = 2)
    backtrack <- isTRUE(backtrack)
    normalize <- isTRUE(normalize)
    if (normalize && step.pattern == 1) stop("Unable to normalize with chosen step pattern.")

    if (backtrack) {
        if (is.null(gcm))
            gcm <- matrix(0, NROW(x) + 1L, NROW(y) + 1L)
        else if (!is.matrix(gcm) || nrow(gcm) < (NROW(x) + 1L) || ncol(gcm) < (NROW(y) + 1L))
            stop("dtw_basic: Dimension inconsistency in 'gcm'")
    }
    else {
        if (is.null(gcm))
            gcm <- matrix(0, 2L, NROW(y) + 1L)
        else if (!is.matrix(gcm) || nrow(gcm) < 2L || ncol(gcm) < (NROW(y) + 1L))
            stop("dtw_basic: Dimension inconsistency in 'gcm'")
    }

    if (storage.mode(gcm) != "double")
        stop("dtw_basic: If provided, 'gcm' must have 'double' storage mode.")

    d <- .Call(C_dtw_basic, x, y, window.size,
               NROW(x), NROW(y), NCOL(x),
               norm, step.pattern, backtrack, normalize,
               gcm, PACKAGE = "dtwclust")

    if (backtrack) {
        d$index1 <- d$index1[d$path:1L]
        d$index2 <- d$index2[d$path:1L]
        d$path <- NULL
    }

    # return
    d
}

# ==================================================================================================
# Wrapper for proxy::dist
# ==================================================================================================

#' @importFrom bigmemory describe
#' @importFrom bigmemory is.big.matrix
#'
dtw_basic_proxy <- function(x, y = NULL, ..., gcm = NULL, error.check = TRUE, pairwise = FALSE) {
    dots <- list(...)
    x <- tslist(x)

    if (error.check) check_consistency(x, "vltslist")

    if (is.null(y)) {
        y <- x
        symmetric <- is.null(dots$window.size) || !different_lengths(x)

    } else {
        y <- tslist(y)
        if (error.check) check_consistency(y, "vltslist")
        symmetric <- FALSE
    }

    if (is.null(gcm)) gcm <- matrix(0, 2L, max(sapply(y, NROW)) + 1L)
    dots$gcm <- gcm
    pairwise <- isTRUE(pairwise)
    dim_out <- c(length(x), length(y))
    dim_names <- list(names(x), names(y))

    # Get appropriate matrix/big.matrix
    D <- allocate_distmat(length(x), length(y), pairwise, symmetric) # UTILS-utils.R
    # Wrap as needed for foreach
    eval(foreach_wrap_expression) # UTILS-expressions-proxy.R

    if (bigmemory::is.big.matrix(D)) {
        D_desc <- bigmemory::describe(D)
        noexport <- "D"
        packages <- c("dtwclust", "bigmemory")

    } else {
        D_desc <- NULL
        noexport <- ""
        packages <- c("dtwclust")
    }

    # Calculate distance matrix
    foreach_extra_args <- list()
    .distfun_ <- dtwb_loop
    eval(foreach_loop_expression) # UTILS-expressions-proxy.R

    if (pairwise) {
        class(D) <- "pairdist"

    } else {
        if (is.null(dim(D))) dim(D) <- dim_out
        dimnames(D) <- dim_names
        class(D) <- "crossdist"
    }

    attr(D, "method") <- "DTW_BASIC"
    # return
    D
}

# ==================================================================================================
# Wrapper for C++
# ==================================================================================================

#' @importFrom dtw symmetric1
#' @importFrom dtw symmetric2
#'
dtwb_loop <- function(d, x, y, symmetric, pairwise, endpoints, bigmat, ..., normalize = FALSE,
                      window.size = NULL, norm = "L1", step.pattern = dtw::symmetric2, gcm)
{
    if (is.null(window.size))
        window.size <- -1L
    else
        window.size <- check_consistency(window.size, "window")

    if (identical(step.pattern, dtw::symmetric1))
        step.pattern <- 1
    else if (identical(step.pattern, dtw::symmetric2))
        step.pattern <- 2
    else
        stop("step.pattern must be either symmetric1 or symmetric2 (without quotes)")

    normalize <- isTRUE(normalize)
    if (normalize && step.pattern == 1) stop("Unable to normalize with chosen step pattern.")
    norm <- match.arg(norm, c("L1", "L2"))
    norm <- switch(norm, "L1" = 1, "L2" = 2)
    mv <- is_multivariate(c(x, y))
    backtrack <- FALSE

    nc <- max(sapply(y, NROW)) + 1L
    if (!is.matrix(gcm) || nrow(gcm) < 2L || ncol(gcm) < nc)
        stop("dtw_basic: Dimension inconsistency in 'gcm'")
    if (storage.mode(gcm) != "double")
        stop("dtw_basic: If provided, 'gcm' must have 'double' storage mode.")

    fill_type <- if (pairwise) "PAIRWISE" else if (symmetric) "SYMMETRIC" else "GENERAL"
    mat_type <- if (bigmat) "BIG_MATRIX" else "R_MATRIX"
    distargs <- list(window.size = window.size,
                     norm = norm,
                     step.pattern = step.pattern,
                     backtrack = backtrack,
                     gcm = gcm,
                     is.multivariate = mv,
                     normalize = normalize)
    # return
    .Call(C_distmat_loop,
          d, x, y,
          "DTW_BASIC", distargs,
          fill_type, mat_type, endpoints,
          PACKAGE = "dtwclust")
}