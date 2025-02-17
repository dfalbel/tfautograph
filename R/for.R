

ag_for <- function(var, iterable, body) {
  var  <- substitute(var)
  body <- substitute(body)
  env  <- parent.frame()

  ag_for_impl(iterable, var, body, env)
}


ag_for_impl <- function(iterable, var, body, env) UseMethod("ag_for_impl")

ag_for_impl.default <- function(iterable, var, body, env) {
  eval(as.call(list(quote(.Primitive("for")), var, iterable, body)), env)
}


did_not_raise_StopIteration <- function(expr) {
  tryCatch({
    force(expr)
    TRUE
  },
  error = function(e)
    grepl("StopIteration", e))
}

#' @importFrom reticulate iter_next
active_iterator_get_next <- function() {
  # it <- peek_active_iterator()
  # it$`__next__`()
  iter_next(peek_active_iterator())
}

#' @importFrom reticulate as_iterator
ag_for_impl.python.builtin.iterator <-
  function(iterable, var, body, env) {
    register_active_iterator(as_iterator(iterable))
    on.exit(pop_registered_active_iterator())

    # expr <- substitute(
    #   while (tfautograph:::did_not_raise_StopIteration(
    #     var <- tfautograph:::active_iterator_get_next()))
    #   body, list(var = var, body = body))

    expr <- substitute(
      while (!is.null(var <- tfautograph:::active_iterator_get_next()))
        body, list(var = var, body = body))

    eval(expr, env)
  }


#' @importFrom zeallot %->%
ag_for_impl.tensorflow.tensor <- function(iterable, var, body, env) {

  if(tf$executing_eagerly() && is_eager(iterable))
    return(ag_for_impl.python.builtin.iterator(
      as_iterator(iterable), var, body, env))

  # track python tensorflow TODO, reimplement here if implementation there changes:
  ## TODO(b/117628877): Revisit performance once XLA has the necessary support.
  ## Note: using a TensorArray creates an extra copy, but can calculate
  ## gradients more efficiently than StridedSlice.
  n <- tf$python$autograph$operators$len_(iterable)
  ta <- tf$TensorArray(iterable$dtype, size = n)
  iter <- ta$unstack(iterable)

  loop_vars <-
    get_registered_next_while_loop_vars() %||%
    get_existing_var_nms(body, var, env = env)

  var <- deparse(var)

  .body_fn <- as_loop_body_fn(body,  unique(c(loop_vars, var)), env,
                              dont_check = var)

  body_fn <- function(index, loop_vars = NULL, did_break = NULL) {
    loop_vars[[var]] <- iter$read(index)
    res <- .body_fn(loop_vars, did_break)
    if(!exists(var, envir = env))
      res[[1]][[var]] <- NULL

    c(index + 1L, res)
  }

  cond_fn <- function(index, loop_vars = NULL, did_break = NULL) {
    continue <- index < n
    if (!is.null(did_break))
      continue <- !did_break & continue
    continue
  }

  can_break <- any(c("break", "return") %in% all.names(body, unique = TRUE))
  did_break <- if(can_break) FALSE else NULL

  index <- 0L

  loop_vars <- mget(loop_vars, env, inherits = TRUE)

  while_loop_args <- c(
    list(
      cond = cond_fn,
      body = body_fn,
      loop_vars = drop_empty(list(index, loop_vars, did_break)),
      return_same_structure = TRUE
    ),
    name = get_next_ag_name(),
    get_registered_next_while_loop_opts()
  )

  if(tf_v2())
    while_loop_args$return_same_structure <- NULL

  res <- do.call(tf$while_loop, while_loop_args)

  # activate_undefs(undefs, sym)
  loop_vars <- res[[2]]
  if(length(loop_vars))
    list2env(loop_vars, envir = env)

  invisible()
}

#' @importFrom tensorflow tf_version
tf_v2 <- function() package_version(tf_version()) >= "2"
tf_v1 <- function() package_version(tf_version()) < "2"

