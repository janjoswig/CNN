# distutils: language = c++
# distutils: extra_compile_args = -fopenmp
# distutils: extra_link_args = -fopenmp
# cython: language_level=3
# cython: boundscheck = False
# cython: wraparound = False
# cython: cdivision = True
# cython: nonecheck = False

cimport cython
from cython.operator cimport dereference as deref, preincrement as princ
from cython.parallel cimport prange
from libcpp.map cimport map as cppmap
from libcpp.utility cimport pair
from libcpp.queue cimport queue as cppqueue
from libcpp.set cimport set as cppset
from libcpp.vector cimport vector
import numpy as np
cimport numpy as np


# ctypedef np.uintp_t ARRAYINDEX_DTYPE_t
ctypedef np.intp_t ARRAYINDEX_DTYPE_t
# ARRAYINDEX_DTYPE = np.uintp
ARRAYINDEX_DTYPE = np.intp

ctypedef unsigned long c_t
ctypedef double r_t

ctypedef fused index_t:
    ARRAYINDEX_DTYPE_t
    Py_ssize_t
    size_t

ctypedef fused npint_or_float:
    np.int32_t
    np.int64_t
    np.float32_t
    np.float64_t

ctypedef fused npinteger:
    np.int32_t
    np.int64_t

ctypedef fused npfloating:
    np.float32_t
    np.float64_t

ctypedef pair[ARRAYINDEX_DTYPE_t, cppset[ARRAYINDEX_DTYPE_t]] NeighbourCacheItem_t
ctypedef cppmap[ARRAYINDEX_DTYPE_t, cppset[ARRAYINDEX_DTYPE_t]] NeighbourCacheData_t
ctypedef cppmap[ARRAYINDEX_DTYPE_t, cppset[ARRAYINDEX_DTYPE_t]].iterator NeighbourCacheIt_t

cdef class CachedNeighbourhoodsPointsArray:
    """Cache design for get_neighbours_PointsArray"""

    # TODO The more generic way would be to associate a function pointer
    #    to a neighbours computing function but this does not go well
    #    with fused types(?)

    cdef:
        NeighbourCacheData_t _cache_data
        cppqueue[ARRAYINDEX_DTYPE_t] _order
        size_t _cachesize

    def __cinit__(self, size_t cachesize):
        self._cachesize = cachesize

    cdef NeighbourCacheIt_t setitem(
            self, NeighbourCacheIt_t it, NeighbourCacheItem_t kvpair):

        if self._order.size() >= self._cachesize:
            self._cache_data.erase(self._order.front())
            self._order.pop()

        self._order.push(kvpair.first)
        return self._cache_data.insert(it, kvpair)

    cdef cppset[ARRAYINDEX_DTYPE_t] evaluate(
            self, ARRAYINDEX_DTYPE_t point, npfloating[:, ::1] points,
            ARRAYINDEX_DTYPE_t n, ARRAYINDEX_DTYPE_t dim,
            r_t radius_cutoff):
        cdef NeighbourCacheIt_t search = self._cache_data.lower_bound(point)

        if search != self._cache_data.end() and point == deref(search).first:
            return deref(search).second
        cdef cppset[ARRAYINDEX_DTYPE_t] neighbours = get_neighbours_PointsArray(
            point, points,
            n, dim,
            radius_cutoff
            )
        return deref(self.setitem(search, NeighbourCacheItem_t(point, neighbours))).second

    @property
    def cache_data(self):
        return self._cache_data


cdef class SparsegraphVector:
    cdef vector[unsigned int] _edges
    cdef vector[unsigned int] _indices

    @property
    def edges(self):
        return self._edges

    @property
    def indices(self):
        return self._indices

    @edges.setter
    def edges(self, x):
        self._edges = x

    @indices.setter
    def indices(self, x):
        self._indices = x


cpdef tuple NeighbourhoodsList2SparsegraphArray(
        list neighbourhoods,
        unsigned int cnn_cutoff):
    """Construct a sparse graph from neighbourhoods

    """

    cdef:
        set neighbours, neighbour_neighbours
        Py_ssize_t point, member, index, n = len(neighbourhoods)
        list edges_list = [], indices_list = []

    index = 0
    for point in range(n):
        indices_list.append(index)
        neighbours = neighbourhoods[point]
        for member in neighbours:
            neighbour_neighbours = neighbourhoods[member]
            if check_similarity_set(
                    neighbours, neighbour_neighbours, cnn_cutoff):
                edges_list.append(member)
                index += 1
    indices_list.append(index)
    return edges_list, indices_list


cdef inline bint check_similarity_set(set a, set b, c_t c):
    """Check if similarity criterion is fulfilled.

    Args:
        a: Python set of point indices
        b: Python set of point indices
        c: Similarity cut-off

    Returns:
        1 if set `a` and set `b` have at least `c` common
        elements, 0 otherwise
    """

    cdef Py_ssize_t x  # Checked element
    cdef c_t common    # Sum of common elements

    if c == 0:  # Trivial case
        return 1

    common = 0
    for x in a:
        if x in b:
            common += 1
            if common == c:
                return 1
    return 0


def _check_similarity_set(set a, set b, c_t c):
    """Python wrapper for `check_similarity_set`

    Made for testing purposes and not normally called in production.
    """
    return check_similarity_set(a, b, c)


cdef inline bint check_similarity_cppset(
        cppset[ARRAYINDEX_DTYPE_t] a, cppset[ARRAYINDEX_DTYPE_t] b,
        c_t c) nogil:
    """Check if similarity criterion is fulfilled.

    Args:
        a: C++ std::set of point (np.ndarray) indices
        b: C++ std::set of point (np.ndarray) indices
        c: Similarity cut-off

    Returns:
        1 if set `a` and set `b` have at least `c` common
        elements, 0 otherwise
    """

    # TODO Except fused type `index_t`

    cdef cppset[ARRAYINDEX_DTYPE_t].iterator it = a.begin()
    cdef cppset[ARRAYINDEX_DTYPE_t].iterator search
    cdef c_t common

    if c == 0:
        return 1

    common = 0
    while it != a.end():
        search = b.find(deref(it))
        if search != b.end():
        # if b.contains(deref(it)):  # C++20 / not wrapped in libcpp.set
            common += 1
            if common == c:
                return 1
        princ(it)
    return 0


def _check_similarity_cppset(set a, set b, c_t c):
    """Python wrapper for `check_similarity_cppset`

    Made for testing purposes and not normally called in production.
    """
    return check_similarity_cppset(a, b, c)


cdef inline bint check_similarity_array(
        ARRAYINDEX_DTYPE_t[::1] a,
        ARRAYINDEX_DTYPE_t sa,
        ARRAYINDEX_DTYPE_t[::1] b,
        c_t c) nogil:
    """Check if the CNN criterion is fullfilled

    Check if `a` and `b` have at least `c` common elements.  Faster than
    computing the intersection (say with `numpy.intersect1d`) and
    comparing its length to `c`.

    Args:
        a, b: 1D Array of integers (neighbor point indices) that
            supports the buffer protocol.
        sa: Length of `a`. Received here because already computed.
        c: Check if `a` and `b` share this many elements.
    Returns:
        1 if set `a` and set `b` have at least `c` common
        elements, 0 otherwise
    """

    cdef ARRAYINDEX_DTYPE_t i, j, sb = b.shape[0]  # Control variables
    cdef ARRAYINDEX_DTYPE_t ai, bj                 # Checked elements
    cdef c_t common = 0                        # Common neighbours count

    if c == 0:
        return 1

    for i in range(sa):
        ai = a[i]
        for j in range(sb):
            bj = b[j]
            if ai == bj:
                # Check similarity and return/move on early
                common += 1
                if common == c:
                    return 1
                break
    return 0


def _check_similarity_array(
        ARRAYINDEX_DTYPE_t[::1] a,
        ARRAYINDEX_DTYPE_t[::1] b,
        c_t c):
    """Python wrapper for `check_similarity_array`

    Made for testing purposes and not normally called in production.
    """
    cdef ARRAYINDEX_DTYPE_t sa = a.shape[0]

    return check_similarity_array(a, sa, b, c)


def fit_from_NeighbourhoodsList(
        neighbourhoods: list,
        cnn_cutoff: int,
        ):
    """Worker function variant applying the CNN algorithm.

    Assigns labels to points starting from pre-computed neighbourhoods.
    Uses Python standard library only.

    Args:
        cnn_cutoff: Points need to share at least this many neighbours
            to be assigned to the same cluster (similarity criterion).
        neighbourhoods: List of length #points containing sets of
            neighbouring point indices

    Returns:
        Labels
    """

    cdef int n, m, k
    cdef vector[int] labels
    cdef vector[int] consider
    cdef vector[int] stack
    cdef int current
    cdef set neighbours, neighbour_neighbours
    cdef int init_point, point, member

   # Number of points
    n = len(neighbourhoods)

    # Initialise labels
    labels = [0 for _ in range(n)]

    # Track assigment
    consider = [1 for _ in range(n)]

    # Start with first cluster (0 = noise)
    current = 1

    for init_point in range(n):
        # Loop over points
        if consider[init_point] == 0:
            # Point already assigned
            continue

        neighbours = neighbourhoods[init_point]
        m = len(neighbours)
        if m <= cnn_cutoff:
            # Point can not fulfill cnn condition
            consider[init_point] = 0           # Mark point as included
            continue

        labels[init_point] = current          # Assign cluster label
        consider[init_point] = 0              # Mark point as included

        point = init_point
        while True:
            # Loop over neighbouring points
            for member in neighbours:
                if consider[member] == 0:
                    # Point already assigned
                    continue

                neighbour_neighbours = neighbourhoods[member]
                k = len(neighbour_neighbours)
                if k <= cnn_cutoff:
                    consider[member] = 0
                    continue

                # conditional growth
                # if (len(neighbours.intersection(neighbourhoods[member]))
                #        >= cnn_cutoff):
                if check_similarity_set(
                        neighbours, neighbour_neighbours, cnn_cutoff):
                    labels[member] = current
                    consider[member] = 0
                    stack.push_back(member)

            if stack.size() == 0:
                # No points left to check
                break

            while stack.size() > 0:
                point = stack.back()  # Get the next point from the queue
                stack.pop_back()
                neighbours = neighbourhoods[point]
                m = len(neighbours)
                if m <= cnn_cutoff:
                    # Point can not fulfill cnn condition
                    consider[init_point] = 0           # Mark point as included
                    continue
                break

        current += 1

    return labels


def fit_from_NeighbourhoodsArray(
        object[::1] neighborhoods,
        npinteger[::1] labels,
        c_t cnn_cutoff):

    cdef ARRAYINDEX_DTYPE_t init_point, point, member  # Points
    cdef ARRAYINDEX_DTYPE_t i, n, m, member_i  # Number of points, neighbours
    cdef ARRAYINDEX_DTYPE_t[::1] neighbors, neighbor_neighbors
    cdef npinteger membercount, current
    cdef vector[ARRAYINDEX_DTYPE_t] stack  # LIFO queue / stack

    current = 0
    # Cluster number (start at 0; noise = -1)

    n = neighborhoods.shape[0]

    # cdef npinteger[::1] labels = np.zeros(n, dtype=np.intp)
    cdef np.uint8_t[::1] consider = np.ones(n, dtype=np.uint8)

    for i in range(n):
        if neighborhoods[i].shape[0] <= cnn_cutoff:
            consider[i] = 0

    for init_point in range(n):
        # loop over points
        if consider[init_point] == 0:
            # Not enough neighbours
            continue

        labels[init_point] = current     # Assign cluster label
        consider[init_point] = 0  # Mark point as included

        point = init_point
        membercount = 1                  # Current cluster size
        while True:
            # Loop over neighbouring points
            neighbors = neighborhoods[point]
            m = neighbors.shape[0]
            for member_i in range(m):
                member = neighbors[member_i]
                if consider[member] == 0:
                    # Point already assigned or not enough neighbours
                    continue

                neighbor_neighbors = neighborhoods[member]
                if check_similarity_array(  # Conditional growth
                        neighbors, m, neighbor_neighbors, cnn_cutoff):
                    labels[member] = current     # Assign cluster label
                    consider[member] = 0  # Point included
                    membercount += 1             # Cluster grows
                    stack.push_back(member)      # Add point to queue

            if stack.size() == 0:
                # No points left to check
                if membercount < 2:
                    # Cluster to small -> effectively noise
                    labels[init_point] = -1  # Revert assignment
                    current -= 1             # Revert cluster number
                break

            point = stack.back()  # Get the next point from the queue
            stack.pop_back()

        current += 1  # Increase cluster number


cpdef fit_from_NeighbourhoodsSparsegraphVector():
    """fit"""

    pass


cpdef fit_from_NeighbourhoodsSparsegraphArray():
    """fit"""

    pass


def predict_from_NeighbourhoodsList(
        c_t cnn_cutoff,
        list neighbourhoods,
        int[::1] labels,
        int[::1] consider,
        int[::1] base_labels,
        set clusters):
    """"""

    cdef Py_ssize_t point, member
    cdef Py_ssize_t n = labels.shape[0]
    cdef set neighbours

    for point in range(n):
        if consider[point] == 0:
            continue

        neighbours = neighbourhoods[point]
        for member in neighbours:
            if not base_labels[member] in clusters:
                continue

            if check_similarity_set(
                neighbours, neighbourhoods[member], cnn_cutoff):
                consider[point] = 0
                labels[point] = base_labels[member]
                break

    return


cpdef vector[unsigned long] fit_from_SparsegraphVector(
        vector[size_t] edges,
        vector[size_t] indices):
    cdef size_t i, j, n, point, neighbour  # For indexing

    # Initialise visited
    n = indices.size() - 1
    cdef vector[bint] visited
    visited.reserve(n)

    # Initialise labels
    cdef unsigned long current
    cdef vector[unsigned long] labels
    labels.reserve(n)

    for i in range(n):
        visited.push_back(0)
        labels.push_back(0)

    # Queue
    cdef cppqueue[size_t] q

    current = 1
    for i in range(n):
        # Source node
        if visited[i]:
            continue

        visited[i] = 1

        if indices[i + 1] - indices[i] == 0:
            # Isolated
            continue

        labels[i] = current
        q.push(i)

        while q.size() > 0:
            point = q.front()
            q.pop()

            for j in range(indices[point], indices[point + 1]):
                neighbour = edges[j]
                if visited[neighbour]:
                    continue

                visited[neighbour] = 1
                labels[neighbour] = current
                if indices[i + 1] - indices[i] == 0:
                    # Isolated
                    continue
                q.push(neighbour)

        current += 1

    return labels


cpdef np.uint64_t[::1] fit_from_SparsegraphArray(
        np.npy_uintp[::1] edges,
        np.npy_uintp[::1] indices):
    """Find connected components in sparse graph

    """
    # TODO: Fused type for labels (unsigned int/long)?

    cdef np.npy_uintp i, j, n, point, neighbour  # For indexing

    # Initialise visited
    n = indices.shape[0] - 1
    cdef np.uint8_t[::1] visited = np.zeros(n, dtype=np.uint8)

    # Initialise labels
    cdef np.uint64_t current
    cdef np.uint64_t[::1] labels = np.zeros(n, dtype=np.uint64)

    # Queue
    cdef cppqueue[ARRAYINDEX_DTYPE_t] q

    current = 1
    for i in range(n):
        # Source node
        if visited[i] == 1:
            continue

        visited[i] = 1

        if indices[i + 1] - indices[i] == 0:
            # Isolated
            continue

        labels[i] = current
        q.push(i)

        while q.size() > 0:
            point = q.front()
            q.pop()

            for j in range(indices[point], indices[point + 1]):
                neighbour = edges[j]
                if visited[neighbour] == 1:
                    continue

                visited[neighbour] = 1
                labels[neighbour] = current
                if indices[i + 1] - indices[i] == 1:
                    # Dead end
                    continue

                q.push(neighbour)

        current += 1

    return labels


cpdef fit_from_DistancesArray():
    """Fit"""

    pass


cpdef fit_from_PointsArray(
        npfloating[:, ::1] points,
        npinteger[::1] labels,
        r_t radius_cutoff,
        c_t cnn_cutoff):
    """Apply CNN clustering from array of points

    """

    # TODO Currently uses brute force approach to calculate neighbours.
    #    Make neighbour/distance method configurable.

    cdef ARRAYINDEX_DTYPE_t init_point, point,
    cdef ARRAYINDEX_DTYPE_t n = points.shape[0], d = points.shape[1]
    cdef cppset[ARRAYINDEX_DTYPE_t] neighbours, neighbour_neighbours
    cdef CachedNeighbourhoodsPointsArray cached_get_neighbours_PointsArray = CachedNeighbourhoodsPointsArray(100)
    cdef cppset[ARRAYINDEX_DTYPE_t].iterator member

    # TODO Alternative neighbour container: Python Set, Numpy Array

    cdef npinteger current = 1
    cdef npinteger membercount = 1  # Optional for min. clustersize
    cdef cppqueue[ARRAYINDEX_DTYPE_t] q  # Queue

    # visited  # TODO Move out of this function
    cdef np.uint8_t[::1] consider = np.ones(n, dtype=np.uint8)

    radius_cutoff = radius_cutoff**2
    # for distance squared

    for init_point in range(n):
        if consider[init_point] == 0:
            continue
        consider[init_point] = 0

        # neighbours = cached_get_neighbours_PointsArray.evaluate(
        neighbours = get_neighbours_PointsArray(
            init_point, points,
            n, d,
            radius_cutoff
            )

        # TODO Pass pointer to points

        if neighbours.size() <= cnn_cutoff:
            continue

        labels[init_point] = current
        membercount = 1
        # point = init_point

        while True:
            member = neighbours.begin()
            while member != neighbours.end():
                if consider[deref(member)] == 0:
                    princ(member)
                    continue

                # neighbour_neighbours = cached_get_neighbours_PointsArray.evaluate(
                neighbour_neighbours = get_neighbours_PointsArray(
                    deref(member), points,
                    n, d,
                    radius_cutoff
                    )

                if neighbour_neighbours.size() <= cnn_cutoff:
                    consider[deref(member)] = 0
                    princ(member)
                    continue

                if check_similarity_cppset(
                        neighbours, neighbour_neighbours, cnn_cutoff) == 1:
                    consider[deref(member)] = 0
                    labels[deref(member)] = current
                    membercount += 1
                    q.push(deref(member))

                princ(member)

            if q.empty():
                if membercount == 1:
                    # Revert cluster assignment
                    labels[init_point] = 0
                    current -= 1
                break

            point = q.front()  # Get the next point from the queue
            q.pop()

            # neighbours = cached_get_neighbours_PointsArray.evaluate(
            neighbours = get_neighbours_PointsArray(
                point, points,
                n, d,
                radius_cutoff
                )

        current += 1


cdef inline cppset[ARRAYINDEX_DTYPE_t] get_neighbours_PointsArray(
        ARRAYINDEX_DTYPE_t point,
        npfloating[:, ::1] points,
        ARRAYINDEX_DTYPE_t n, ARRAYINDEX_DTYPE_t dim,
        r_t radius_cutoff):
    """Caculate neighbours of a point"""

    # TODO Currently uses brute force approach to calculate neighbours.
    #    Make distance method configurable.

    # TODO Cache neighbourhoods

    # TODO Return pointer to neighbours

    # TODO nogil?

    cdef cppset[ARRAYINDEX_DTYPE_t] neighbours
    cdef ARRAYINDEX_DTYPE_t i
    cdef npfloating[::1] p = points[point]
    cdef r_t r

    for i in range(n):
        if i == point:
            # No self counting
            continue

        # TODO Test with self counting

        r = get_distance_squared_euclidean_PointsArray(
                p, points[i], dim
                )

        if r <= radius_cutoff:
            neighbours.insert(i)

    return neighbours


def _get_neighbours_PointsArray(
        ARRAYINDEX_DTYPE_t point,
        npfloating[:, ::1] points,
        r_t radius_cutoff):
    """Python wrapper for `get_neighbours_PointsArray`

    Made for testing purposes and not normally called in production.
    """

    cdef ARRAYINDEX_DTYPE_t n = points.shape[0]
    cdef ARRAYINDEX_DTYPE_t dim = points.shape[1]

    return get_neighbours_PointsArray(
        point, points,
        n, dim,
        radius_cutoff
        )


cdef inline r_t get_distance_squared_euclidean_PointsArray_p(
        npfloating[::1] a, npfloating[::1] b, ARRAYINDEX_DTYPE_t dim) nogil:
    """Calculate squared euclidean distance between points (parallel)

    Args:
        a, b: Point container supporting the buffer protocol. `a`
            and `b` have to be of length >= `dim`.
        dim: Dimensions to consider.
    """

    cdef r_t total = 0
    cdef ARRAYINDEX_DTYPE_t i

    for i in prange(dim):
        total += (a[i] - b[i])**2

    # TODO Test serial vs. parallel

    return total


cdef inline r_t get_distance_squared_euclidean_PointsArray(
        npfloating[::1] a, npfloating[::1] b, ARRAYINDEX_DTYPE_t dim) nogil:
    """Calculate squared euclidean distance between points (serial)

    Args:
        a, b: Point container supporting the buffer protocol. `a`
            and `b` have to be of length >= `dim`.
        dim: Dimensions to consider.
    """

    cdef r_t total = 0
    cdef ARRAYINDEX_DTYPE_t i

    for i in range(dim):
        total += (a[i] - b[i])**2

    return total


def _get_distance_squared_euclidean_PointsArray(
        npfloating[::1] a, npfloating[::1] b, bint parallel):
    """Python wrapper for `get_distance_squared_euclidean_PointsArray`

    Made for testing purposes and not normally called in production.

    Args:
        parallel: Choose parallel computation
    """
    cdef ARRAYINDEX_DTYPE_t dim = a.shape[0]

    if parallel:
        return get_distance_squared_euclidean_PointsArray_p(a, b, dim)
    else:
        return get_distance_squared_euclidean_PointsArray(a, b, dim)